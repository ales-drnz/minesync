// Test del motore contro l'hub finto. I nomi citano le regole di
// docs/spec/behaviour.md che verificano.
import 'dart:convert';
import 'dart:io';

import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'package:ms_core/testing/fake_hub.dart';

void main() {
  late FakeHub hub;
  late HubClient client;
  late HashPool pool;
  late Directory tmp;
  late String space;

  setUpAll(() => pool = HashPool.spawn(2));
  tearDownAll(() => pool.close());

  setUp(() async {
    hub = await FakeHub.start();
    client = HubClient(hub.uri, idleTimeout: const Duration(seconds: 2));
    tmp = Directory.systemTemp.createTempSync('ms_engine');
    space = hub.createSpace('Survival');
  });

  tearDown(() async {
    client.close(force: true);
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  SyncEngine engine(String name) => SyncEngine(
    client,
    space,
    '${tmp.path}/$name',
    pool: pool,
    retryDelay: const Duration(milliseconds: 10),
  );

  File put(String dir, String rel, String content) => File('${tmp.path}/$dir/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  String read(String dir, String rel) => File('${tmp.path}/$dir/$rel').readAsStringSync();
  bool exists(String dir, String rel) => File('${tmp.path}/$dir/$rel').existsSync();

  Future<PushResult> push(String dir, {bool confirm = false}) async {
    final lock = await client.acquireLock(space, const LockInfo());
    try {
      return await engine(dir).push(lock: lock, confirmMassDelete: confirm);
    } finally {
      await client.releaseLock(space, lock.token);
    }
  }

  TypeMatcher<SyncException> kind(SyncErrorKind k) =>
      isA<SyncException>().having((e) => e.kind, 'kind', k);

  test('B-PUSH-01 B-PUSH-16 push e pull tra due cartelle', () async {
    put('a', 'server.properties', 'motd=1');
    put('a', 'world/level.dat', 'L1');
    put('a', 'logs/latest.log', 'escluso');
    final r = await push('a');
    expect(r.generation!.n, 1);
    expect(hub.head(space)!.manifest.files.keys, ['server.properties', 'world/level.dat']);

    final p = await engine('b').pull();
    expect(p.n, 1);
    expect(read('b', 'world/level.dat'), 'L1');
    expect(exists('b', 'logs/latest.log'), isFalse);

    // la base locale è la generazione appena caricata: il push dopo è vuoto
    expect((await push('a')).generation, isNull);
    expect(LocalState('${tmp.path}/a').loadBase(space)!.digest, hub.head(space)!.digest);
  });

  test('B-PUSH-20 ogni richiesta porta X-MineSync', () async {
    put('a', 'x', '1');
    await push('a');
    await engine('b').pull();
    expect(hub.missingHeader, isEmpty);
  });

  test(
    'B-PULL-01 B-PULL-02 modifiche locali non caricate bloccano il pull (non divergente)',
    () async {
      put('a', 'x', '1');
      await push('a');
      put('a', 'x', 'locale');
      await expectLater(
        engine('a').pull(),
        throwsA(kind(SyncErrorKind.dirtyLocal).having((e) => e.diverged, 'diverged', isFalse)),
      );
      expect(read('a', 'x'), 'locale');
      // fast-forward: push, poi il pull va
      expect((await push('a')).generation!.n, 2);
      await engine('a').pull();
      expect(read('a', 'x'), 'locale');
    },
  );

  test('B-PULL-03 divergente se qualcun altro ha caricato dopo la base', () async {
    put('a', 'x', '1');
    await push('a');
    hub.commitDirect(space, {'x': utf8.encode('di bob')});
    put('a', 'x', 'mio');
    await expectLater(
      engine('a').pull(),
      throwsA(kind(SyncErrorKind.dirtyLocal).having((e) => e.diverged, 'diverged', isTrue)),
    );
  });

  test('B-PULL-04 scartare le modifiche locali le copia prima in backup', () async {
    put('a', 'x', '1');
    await push('a');
    hub.commitDirect(space, {'x': utf8.encode('di bob')});
    put('a', 'x', 'mio');
    final r = await engine('a').pull(discardLocal: true);
    expect(read('a', 'x'), 'di bob');
    expect(r.backup, isNotNull);
    expect(File('${r.backup}/x').readAsStringSync(), 'mio');
    expect(
      r.backup!.replaceAll(r'\', '/'),
      startsWith('${tmp.path.replaceAll(r'\', '/')}/a/.minesync/backup/'),
    );
  });

  test('B-PULL-05 file solo mancanti in locale si riscaricano', () async {
    put('a', 'x', '1');
    put('a', 'y', '2');
    await push('a');
    File('${tmp.path}/a/x').deleteSync();
    await engine('a').pull();
    expect(read('a', 'x'), '1');
  });

  test('B-PULL-06 B-PULL-07 pull interrotto: si ripete e salva le modifiche', () async {
    put('a', 'x', '1');
    put('a', 'big', 'B' * 1000);
    await push('a');
    final hb = hub.commitDirect(space, {'x': utf8.encode('2'), 'big': utf8.encode('C' * 1000)});
    await engine('b').pull().catchError((Object _) => throw StateError('primo pull'));
    // b ha la gen 2; ora a è alla 1. Simula un pull di a interrotto a metà
    hub.stall.add(hb.manifest['big']!.h);
    await expectLater(engine('a').pull(), throwsA(isA<TransferStalled>()));
    expect(LocalState('${tmp.path}/a').loadPullTarget(), isNotNull);
    hub.stall.clear();
    put('a', 'x', 'modifica durante');
    final r = await engine('a').pull();
    expect(read('a', 'x'), '2');
    expect(read('a', 'big'), 'C' * 1000);
    expect(File('${r.backup}/x').readAsStringSync(), 'modifica durante');
    expect(LocalState('${tmp.path}/a').loadPullTarget(), isNull);
    expect((await push('a')).generation, isNull);
  });

  test('B-PULL-08 generazione riscritta con lo stesso numero: base sconosciuta', () async {
    put('a', 'x', '1');
    await push('a');
    hub.rewriteHead(space, {'x': utf8.encode('backup vecchio')});
    put('a', 'x', 'mio');
    await expectLater(engine('a').pull(), throwsA(kind(SyncErrorKind.dirtyLocal)));
    await expectLater(push('a'), throwsA(kind(SyncErrorKind.staleBase)));
  });

  test('B-PULL-09 manifest con percorsi pericolosi rifiutato, niente scritto', () async {
    // l'hub finto accetta solo manifest validi: si simula alterando la risposta
    final evil = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => evil.close(force: true));
    evil.listen((req) async {
      final segs = req.uri.pathSegments;
      req.response.headers.contentType = ContentType.json;
      if (segs.last == 'survival') {
        req.response.write(
          '{"id":"survival","name":"S","profile":"minecraft","createdAt":0,"lock":null,'
          '"head":{"n":1,"parent":0,"digest":"${'0' * 64}","authorId":"x","author":"x","message":"",'
          '"ts":0,"kind":"push","stats":{"files":1,"size":1}},"exclusions":[],"ownExclusions":[]}',
        );
      } else {
        req.response.write(
          '{"n":1,"parent":0,"digest":"${'0' * 64}","authorId":"x","author":"x","message":"",'
          '"ts":0,"kind":"push","stats":{"files":1,"size":1},'
          '"manifest":{"../evil":{"size":1,"h":"${'a' * 64}"}}}',
        );
      }
      await req.response.close();
    });
    final c = HubClient(Uri.parse('http://127.0.0.1:${evil.port}/'));
    addTearDown(() => c.close(force: true));
    final e = SyncEngine(c, 'survival', '${tmp.path}/z', pool: pool);
    await expectLater(e.pull(), throwsA(kind(SyncErrorKind.badManifest)));
    expect(File('${tmp.path}/evil').existsSync(), isFalse);
  });

  test('B-GUARD-04 push da cartella vuota contro hub pieno: rifiutato senza richieste', () async {
    put('a', 'x', '1');
    await push('a');
    File('${tmp.path}/a/x').deleteSync();
    hub.calls.clear();
    await expectLater(push('a'), throwsA(kind(SyncErrorKind.massDelete)));
    expect(hub.calls.keys.where((k) => k.contains('pushes')), isEmpty);
  });

  test('B-GUARD-01 guardia dell\'hub: più della metà dei file', () async {
    for (var i = 0; i < 30; i++) {
      put('a', 'f$i', '$i');
    }
    await push('a');
    for (var i = 0; i < 20; i++) {
      File('${tmp.path}/a/f$i').deleteSync();
    }
    await expectLater(push('a'), throwsA(kind(SyncErrorKind.massDelete)));
  });

  test('B-GUARD-01 soglia dello spazio dall\'hub: il client si ferma prima di caricare', () async {
    for (var i = 0; i < 10; i++) {
      put('a', 'f$i', '$i');
    }
    await push('a');
    hub.setSettings(
      space,
      const SpaceSettings(
        protection: ProtectionSettings(massDeleteRatio: 0.2, massDeleteMinFiles: 5),
      ),
    );
    for (var i = 0; i < 3; i++) {
      File('${tmp.path}/a/f$i').deleteSync();
    }
    hub.calls.clear();
    await expectLater(
      push('a'),
      throwsA(
        kind(
          SyncErrorKind.massDelete,
        ).having((e) => e.removed.toSet(), 'removed', {'f0', 'f1', 'f2'}),
      ),
    );
    expect(hub.calls.keys.where((k) => k.contains('pushes')), isEmpty);
    // con la conferma (admin) passa
    hub.admin = true;
    expect((await push('a', confirm: true)).generation!.n, 2);
    // soglia di fabbrica (0.5, 20 file): 3 su 7 non la toccano
    hub.setSettings(space, null);
    File('${tmp.path}/a/f3').deleteSync();
    expect((await push('a')).generation!.n, 3);
  });

  test(
    'B-GUARD-05 B-GUARD-06 hub vuoto: rifiuta su cartella piena, va su cartella vuota',
    () async {
      put('a', 'x', '1');
      await expectLater(engine('a').pull(), throwsA(kind(SyncErrorKind.dirtyLocal)));
      await expectLater(
        engine('a').pull(discardLocal: true),
        throwsA(kind(SyncErrorKind.emptyRemote)),
      );
      expect(read('a', 'x'), '1');
      final r = await engine('vuota').pull();
      expect(r.n, 0);
    },
  );

  test('B-GUARD-07 base vecchia: push rifiutato senza richieste', () async {
    put('a', 'x', '1');
    await push('a');
    hub.commitDirect(space, {'x': utf8.encode('2')});
    put('a', 'x', '3');
    hub.calls.clear();
    await expectLater(push('a'), throwsA(kind(SyncErrorKind.staleBase)));
    expect(hub.calls.keys.where((k) => k.contains('pushes')), isEmpty);
  });

  test('B-GUARD-08 cache locale persa con hub non vuoto: push rifiutato', () async {
    put('a', 'x', '1');
    await push('a');
    Directory('${tmp.path}/a/.minesync').deleteSync(recursive: true);
    await expectLater(push('a'), throwsA(kind(SyncErrorKind.staleBase)));
  });

  test('B-PUSH-13 risposta del commit persa: si riprova lo stesso push', () async {
    put('a', 'x', '1');
    hub.dropNextCommitResponse = true;
    final r = await push('a');
    expect(r.generation!.n, 1);
    expect(hub.head(space)!.n, 1);
    expect((await push('a')).generation, isNull);
  });

  test('B-PUSH-15 B-PUSH-04 lock rubato durante il push: niente commit', () async {
    put('a', 'x', '1');
    final lock = await client.acquireLock(space, const LockInfo());
    hub.stealLock(space, 'bob');
    await expectLater(engine('a').push(lock: lock), throwsA(kind(SyncErrorKind.lockLost)));
    expect(hub.head(space), isNull);
  });

  test('B-LOCK-12 B-LOCK-16 il keeper tiene vivo il lock e si accorge della perdita', () async {
    hub.heartbeatMs = 50;
    final lock = await client.acquireLock(space, const LockInfo());
    final ct = CancelToken();
    final k = LockKeeper(client, space, lock, cancel: ct)..start();
    await Future<void>.delayed(const Duration(milliseconds: 220));
    expect(k.beats, greaterThanOrEqualTo(2));
    hub.stealLock(space, 'bob');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(ct.isCancelled, isTrue);
    expect(ct.reason!.kind, SyncErrorKind.lockLost);
    k
      ..stop()
      ..stop();
  });

  test('B-PUSH-18 solo il bit di esecuzione: push e pull come chmod', () async {
    put('a', 'run.sh', '#!/bin/sh');
    await push('a');
    await engine('b').pull();
    await Process.run('chmod', ['+x', '${tmp.path}/a/run.sh']);
    expect((await push('a')).generation!.n, 2);
    hub.calls.clear();
    await engine('b').pull();
    expect(hub.calls.keys.where((k) => k.startsWith('GET blobs')), isEmpty);
    expect(FileStat.statSync('${tmp.path}/b/run.sh').mode & 0x40, isNonZero);
  }, testOn: '!windows');

  test('B-PUSH-19 file illeggibile: il push tiene la versione dell\'hub', () async {
    put('a', 'x', '1');
    put('a', 'locked.dat', 'segreto');
    await push('a');
    put('a', 'x', '2');
    await Process.run('chmod', ['000', '${tmp.path}/a/locked.dat']);
    addTearDown(() => Process.runSync('chmod', ['644', '${tmp.path}/a/locked.dat']));
    final r = await push('a');
    expect(r.kept, ['locked.dat']);
    expect(hub.head(space)!.manifest.files.keys, containsAll(['x', 'locked.dat']));
  }, testOn: '!windows');

  test('download corrotto: riprova e poi errore, niente file scritto', () async {
    put('a', 'x', 'contenuto');
    await push('a');
    hub.corrupt.add(hub.head(space)!.manifest['x']!.h);
    await expectLater(engine('b').pull(), throwsA(kind(SyncErrorKind.corruptDownload)));
    expect(exists('b', 'x'), isFalse);
    expect(
      Directory(
        '${tmp.path}/b',
      ).listSync(recursive: true).where((e) => e.path.endsWith(partSuffix)),
      isEmpty,
    );
  });

  test('B-PUSH-26 download fermo: il watchdog lo interrompe', () async {
    put('a', 'x', 'contenuto');
    await push('a');
    hub.stall.add(hub.head(space)!.manifest['x']!.h);
    final sw = Stopwatch()..start();
    await expectLater(engine('b').pull(), throwsA(isA<TransferStalled>()));
    expect(sw.elapsed, lessThan(const Duration(seconds: 30)));
  });

  test('file grande: pull riusa i chunk locali invariati', () async {
    final data = List.generate(6 << 20, (i) => (i * 7 + (i >> 11)) & 0xff);
    File('${tmp.path}/a/world/region/r.0.0.mca')
      ..createSync(recursive: true)
      ..writeAsBytesSync(data);
    await push('a');
    await engine('b').pull();
    // cambia pochi byte nel mezzo e carica
    data[3 << 20] ^= 0xff;
    File('${tmp.path}/a/world/region/r.0.0.mca').writeAsBytesSync(data);
    final r = await push('a');
    expect(r.uploaded, lessThanOrEqualTo(2));
    hub.calls.clear();
    await engine('b').pull();
    expect(hub.calls['GET blobs'] ?? 0, lessThanOrEqualTo(2));
    expect(File('${tmp.path}/b/world/region/r.0.0.mca').readAsBytesSync(), data);
  });

  test('B-PULL-12 cartelle vuote potate, quelle escluse no', () async {
    put('a', 'world/dim/x', '1');
    put('a', 'keep', '1');
    await push('a');
    await engine('b').pull();
    File('${tmp.path}/a/world/dim/x').deleteSync();
    await push('a');
    Directory('${tmp.path}/b/backups').createSync();
    await engine('b').pull();
    expect(Directory('${tmp.path}/b/world').existsSync(), isFalse);
    expect(Directory('${tmp.path}/b/backups').existsSync(), isTrue);
  });
}
