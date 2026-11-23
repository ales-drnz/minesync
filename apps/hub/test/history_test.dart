// Storia: file danneggiati, differenze, export ZIP,
// eliminazione di una generazione, ripristino di un file.
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late TestHub t;
  late String space;
  setUp(() async {
    t = await TestHub.start();
    space = await t.createSpace('Survival');
  });
  tearDown(() => t.close());

  String hashOf(List<int> b) => sha256Hex(Uint8List.fromList(b));

  /// Push con file danneggiati segnalati.
  Future<Res> pushDamaged(Map<String, List<int>> files, List<DamagedFile> damaged) async {
    final tok = t.tokens['$space/alice'] ?? await t.lock(space);
    final h = await t.head(space);
    final b = await t.req(
      'POST',
      '/spaces/$space/pushes',
      body: PushBegin(
        parent: h.n,
        parentDigest: h.digest,
        lockToken: tok,
        manifest: manifestOf(files),
        damaged: damaged,
      ).toJson(),
    );
    if (b.status != 201) return b;
    final id = b.obj['pushId']! as String;
    final byHash = {for (final c in files.values) hashOf(c): c};
    for (final hh in (b.obj['missing']! as List<Object?>).cast<String>()) {
      await t.req('PUT', '/pushes/$id/blobs/$hh', raw: byHash[hh]);
    }
    return t.req('POST', '/pushes/$id/commit');
  }

  Future<void> unlock() async {
    final tok = t.tokens.remove('$space/alice');
    if (tok != null) await t.req('DELETE', '/spaces/$space/lock', body: {'token': tok});
  }

  group('file danneggiati', () {
    test('B-GEN-11 restano nella generazione e nel riassunto', () async {
      final r = await pushDamaged(
        {'world/region/r.0.0.mca': bytes('rotto'), 'level.dat': bytes('ok')},
        [const DamagedFile(path: 'world/region/r.0.0.mca', bad: 3, total: 1024)],
      );
      expect(r.status, 200, reason: '$r');
      final s = GenerationSummary.fromJson(r.json);
      expect(s.damaged.single.path, 'world/region/r.0.0.mca');
      expect(s.damaged.single.bad, 3);
      final h = (await t.get('/spaces/$space/generations')).obj['generations']! as List;
      expect(GenerationSummary.fromJson(h.first).damaged.single.total, 1024);
      await t.restart();
      final g = Generation.fromJson((await t.get('/spaces/$space/generations/1')).json);
      expect(g.summary.damaged, hasLength(1));
    });

    test('un percorso danneggiato che non è nel manifest è bad_path', () async {
      final r = await pushDamaged({'a': bytes('a')}, [const DamagedFile(path: 'b')]);
      expect(r.code, 'bad_path');
      expect(r.details['path'], 'b');
    });
  });

  group('differenze', () {
    test('aggiunti, modificati, rimossi con totale, limite e ordine di percorso', () async {
      await t.push(space, {'a': bytes('1'), 'b': bytes('2'), 'c': bytes('3')});
      await t.push(space, {
        'a': bytes('1'),
        'b': bytes('22'),
        for (var i = 0; i < 5; i++) 'n/$i': bytes('n$i'),
      });
      final r = await t.get('/spaces/$space/generations/2/diff?limit=3');
      final d = GenerationChanges.fromJson(r.json);
      expect(d.n, 2);
      expect(d.parent, 1);
      expect(d.added.total, 5);
      expect([for (final e in d.added.items) e.path], ['n/0', 'n/1', 'n/2']);
      expect(d.added.truncated, isTrue);
      expect(d.changed.items.single.path, 'b');
      expect(d.changed.items.single.size, 2);
      expect(d.changed.items.single.prevSize, 1);
      expect(d.removed.items.single.path, 'c');
      final first = GenerationChanges.fromJson(
        (await t.get('/spaces/$space/generations/1/diff')).json,
      );
      expect(first.parent, 0);
      expect(first.added.total, 3);
      expect((await t.get('/spaces/$space/generations/9/diff')).status, 404);
      expect((await t.get('/spaces/$space/generations/1/diff?limit=1001')).status, 400);
    });

    test('precedente eliminata: confronto con la più recente conservata', () async {
      await t.push(space, {'a': bytes('1')});
      await t.push(space, {'a': bytes('2')});
      await t.push(space, {'a': bytes('2'), 'b': bytes('3')});
      expect((await t.req('DELETE', '/spaces/$space/generations/2', as: 'carol')).status, 200);
      final d = GenerationChanges.fromJson((await t.get('/spaces/$space/generations/3/diff')).json);
      expect(d.parent, 1);
      expect(d.changed.items.single.path, 'a');
      expect(d.added.items.single.path, 'b');
    });

    test('file danneggiati con l\'ultima generazione integra', () async {
      await t.push(space, {'r.mca': bytes('v1')});
      await pushDamaged({'r.mca': bytes('v2')}, [const DamagedFile(path: 'r.mca')]);
      await pushDamaged({'r.mca': bytes('v3')}, [const DamagedFile(path: 'r.mca')]);
      final d = GenerationChanges.fromJson((await t.get('/spaces/$space/generations/3/diff')).json);
      expect(d.damaged.single.file.path, 'r.mca');
      expect(d.damaged.single.lastIntact, 1);
    });
  });

  group('export ZIP', () {
    test('B-SPACE-03 generazione intatta: ZIP con contenuto, file a pezzi ed eseguibili', () async {
      final c1 = noise(3000, 3), c2 = noise(2000, 4);
      final whole = [...c1, ...c2];
      final tok = await t.lock(space);
      final m = Manifest({
        'world/r.mca': FileEntry(
          size: whole.length,
          h: hashOf(whole),
          chunks: [Chunk(hashOf(c1), c1.length), Chunk(hashOf(c2), c2.length)],
        ),
        'start.sh': FileEntry(size: 9, h: hashOf(bytes('#!/bin/sh')), x: true),
        'città/è.txt': FileEntry(size: 0, h: hashOf(const [])),
      });
      final b = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(parent: 0, parentDigest: emptyDigest, lockToken: tok, manifest: m).toJson(),
      );
      final pid = b.obj['pushId']! as String;
      final content = {
        hashOf(c1): c1,
        hashOf(c2): c2,
        hashOf(bytes('#!/bin/sh')): bytes('#!/bin/sh'),
        hashOf(const []): <int>[],
      };
      for (final h in (b.obj['missing']! as List).cast<String>()) {
        await t.req('PUT', '/pushes/$pid/blobs/$h', raw: content[h]);
      }
      expect((await t.req('POST', '/pushes/$pid/commit')).status, 200);
      for (final which in ['1', 'head']) {
        final r = await t.get('/spaces/$space/generations/$which/zip');
        expect(r.status, 200);
        expect(r.headers.contentType?.mimeType, 'application/zip');
        expect(r.headers.contentLength, r.bytes.length);
        expect(r.headers.value('content-disposition'), 'attachment; filename="$space-1.zip"');
        final z = ZipDecoder().decodeBytes(r.bytes, verify: true);
        final files = {for (final f in z.files) f.name: f};
        expect(files.keys, unorderedEquals(['world/r.mca', 'start.sh', 'città/è.txt']));
        expect(files['world/r.mca']!.content, whole);
        expect(files['start.sh']!.content, bytes('#!/bin/sh'));
        expect(files['start.sh']!.mode & 0x1ff, 0x1ed);
        expect(files['world/r.mca']!.mode & 0x1ff, 0x1a4);
      }
    });

    test('B-SPACE-03 un blob mancante: 409 blobs_missing prima di qualunque byte ZIP', () async {
      final lost = bytes('perso');
      await t.push(space, {'a': bytes('ok'), 'b': lost});
      File(t.store.blobs.pathOf(hashOf(lost))).deleteSync();
      final r = await t.get('/spaces/$space/generations/1/zip');
      expect(r.status, 409);
      expect(r.code, 'blobs_missing');
      expect(r.details['missing'], [hashOf(lost)]);
      expect(r.headers.contentType?.mimeType, 'application/json');
    });

    test('ZIP64 (forzato) letto da un decoder indipendente; CRC-32 corretto', () async {
      final dir = await Directory.systemTemp.createTemp('minesync-zip-');
      addTearDown(() => dir.delete(recursive: true));
      final a = noise(70000, 9), b = bytes('secondo');
      File('${dir.path}/a').writeAsBytesSync(a);
      File('${dir.path}/b').writeAsBytesSync(b);
      for (final force in [false, true]) {
        final plan = ZipPlan([
          ZipItem(name: 'a.bin', size: a.length, blobs: const ['a']),
          ZipItem(name: 'dir/b.txt', size: b.length, blobs: const ['b'], exec: true),
        ], force64: force);
        expect(plan.usesZip64, force);
        final out = File('${dir.path}/out$force.zip');
        final sink = out.openWrite();
        await plan.write(sink, (h) => '${dir.path}/$h');
        await sink.close();
        final raw = out.readAsBytesSync();
        expect(raw.length, plan.length);
        final z = ZipDecoder().decodeBytes(raw, verify: true);
        expect(z.findFile('a.bin')!.content, a);
        expect(z.findFile('dir/b.txt')!.content, b);
      }
      final crc = Crc32()..add(bytes('123456789'));
      expect(crc.value, 0xCBF43926);
    });
  });

  group('eliminare una generazione', () {
    test('B-GEN-15 la testa no (409 is_head); le altre sì, con i blob solo loro', () async {
      final only1 = bytes('solo nella 1'), shared = bytes('condiviso');
      await t.push(space, {'a': only1, 's': shared});
      await t.push(space, {'a': bytes('due'), 's': shared});
      await t.push(space, {'a': bytes('tre'), 's': shared});
      expect((await t.req('DELETE', '/spaces/$space/generations/3', as: 'carol')).code, 'is_head');
      expect((await t.req('DELETE', '/spaces/$space/generations/9', as: 'carol')).status, 404);
      expect((await t.req('DELETE', '/spaces/$space/generations/1')).status, 403);
      final freed = await t.get('/spaces/$space/generations/1/freed', as: 'carol');
      expect(freed.obj, {'n': 1, 'bytes': only1.length});
      final r = await t.req('DELETE', '/spaces/$space/generations/1', as: 'carol');
      expect(r.obj, {'deleted': 1, 'bytes': only1.length});
      expect(t.store.blobs.has(hashOf(only1)), isFalse);
      expect(t.store.blobs.has(hashOf(shared)), isTrue);
      final h = (await t.get('/spaces/$space/generations')).obj['generations']! as List;
      expect([for (final g in h) (g as Map)['n']], [3, 2]);
      final e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.generationDelete);
      expect(e.data, {'n': 1, 'bytes': only1.length});
      expect(e.actor, 'carol');
    });

    test('B-GC-05 una generazione illeggibile: 500 e niente cancellato', () async {
      final b1 = bytes('uno');
      await t.push(space, {'a': b1});
      await t.push(space, {'a': bytes('due')});
      await t.push(space, {'a': bytes('tre')});
      File('${t.data}/spaces/$space/generations/2.json').writeAsStringSync('{rotto');
      final r = await t.req('DELETE', '/spaces/$space/generations/1', as: 'carol');
      expect(r.status, 500);
      expect(r.code, 'internal');
      expect(File('${t.data}/spaces/$space/generations/1.json').existsSync(), isTrue);
      expect(t.store.blobs.has(hashOf(b1)), isTrue);
    });

    test('B-GC-04 i blob di un push aperto sopravvivono all\'eliminazione', () async {
      final old = bytes('dedup');
      await t.push(space, {'a': old});
      await t.push(space, {'a': bytes('altro')});
      final h = await t.head(space);
      final b = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: h.n,
          parentDigest: h.digest,
          lockToken: t.tokens['$space/alice']!,
          manifest: manifestOf({'a': old}),
        ).toJson(),
      );
      expect(b.obj['missing'], isEmpty);
      final r = await t.req('DELETE', '/spaces/$space/generations/1', as: 'carol');
      expect(r.obj['bytes'], 0);
      expect(t.store.blobs.has(hashOf(old)), isTrue);
      expect((await t.req('POST', '/pushes/${b.obj['pushId']}/commit')).status, 200);
    });
  });

  group('ripristinare un file', () {
    test('B-GEN-12 sorgente auto: solo quel file, dall\'ultima versione integra', () async {
      await t.push(space, {'r.mca': bytes('integro'), 'x': bytes('x1')});
      await pushDamaged(
        {'r.mca': bytes('rotto'), 'x': bytes('x2'), 'y': bytes('y')},
        [const DamagedFile(path: 'r.mca'), const DamagedFile(path: 'y')],
      );
      await pushDamaged(
        {'r.mca': bytes('rotto2'), 'x': bytes('x3'), 'y': bytes('y')},
        [const DamagedFile(path: 'r.mca'), const DamagedFile(path: 'y')],
      );
      await unlock();
      final r = await t.req(
        'POST',
        '/spaces/$space/restore-file',
        as: 'carol',
        body: const RestoreFileRequest(path: 'r.mca').toJson(),
      );
      expect(r.status, 201, reason: '$r');
      final s = GenerationSummary.fromJson(r.json);
      expect(s.n, 4);
      expect(s.kind, GenerationKind.restore);
      expect(s.restoredFrom, 1);
      expect(s.restoredPath, 'r.mca');
      expect([for (final d in s.damaged) d.path], ['y']);
      final g = Generation.fromJson((await t.get('/spaces/$space/generations/head')).json);
      expect(g.manifest['r.mca']!.h, hashOf(bytes('integro')));
      expect(g.manifest['x']!.h, hashOf(bytes('x3')), reason: 'gli altri file restano della testa');
      final e = t.hub.events.after(0).lastWhere((e) => e.type == EventType.restoreFile);
      expect(e.data, {'n': 4, 'restoredFrom': 1, 'path': 'r.mca'});
    });

    test('sorgente esplicita; nessuna sorgente → 404; percorso non valido → bad_path', () async {
      await t.push(space, {'a': bytes('1')});
      await t.push(space, {'a': bytes('2')});
      await unlock();
      Future<Res> rf(Map<String, Object?> b) =>
          t.req('POST', '/spaces/$space/restore-file', as: 'carol', body: b);
      final r = await rf({'path': 'a', 'from': 2, 'message': 'di nuovo'});
      expect(r.status, 201);
      expect(GenerationSummary.fromJson(r.json).message, 'di nuovo');
      expect((await rf({'path': 'nope'})).status, 404);
      expect((await rf({'path': 'a', 'from': 7})).status, 404);
      expect((await rf({'path': '../a'})).code, 'bad_path');
      expect((await t.req('POST', '/spaces/$space/restore-file', body: {'path': 'a'})).status, 403);
    });

    test('B-GEN-14 rifiutato con un lock vivo, anche dello stesso admin', () async {
      await t.push(space, {'a': bytes('1')});
      await t.push(space, {'a': bytes('2')});
      await unlock();
      await t.lock(space, as: 'carol');
      final r = await t.req(
        'POST',
        '/spaces/$space/restore-file',
        as: 'carol',
        body: {'path': 'a'},
      );
      expect(r.code, 'locked');
    });
  });
}
