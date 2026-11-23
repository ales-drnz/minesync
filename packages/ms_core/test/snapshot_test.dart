// Istantanea, outbox, attesa di quiete e limite di banda (B-PUSH-21..24,
// B-SCAN-08).
import 'dart:async';
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
    client = HubClient(hub.uri);
    tmp = Directory.systemTemp.createTempSync('ms_snap');
    space = hub.createSpace('Survival');
  });
  tearDown(() async {
    client.close(force: true);
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  SyncEngine engine() =>
      SyncEngine(client, space, tmp.path, pool: pool, retryDelay: const Duration(milliseconds: 10));
  File put(String rel, String content) => File('${tmp.path}/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);
  Future<LockGrant> lock() => client.acquireLock(space, const LockInfo());

  test('B-PUSH-21 le modifiche dopo l\'istantanea non entrano in quella generazione', () async {
    put('world/level.dat', 'v1');
    put('a.txt', 'fermo');
    final snap = await engine().snapshot();
    expect(snap, isNotNull);
    expect(Directory('${tmp.path}/.minesync/outbox').listSync(), hasLength(3)); // 2 blob + pending
    put('world/level.dat', 'v2 dopo la foto');
    final r = await engine().pushSnapshot(lock: await lock());
    expect(r!.generation!.n, 1);
    expect(r.generation!.kind, GenerationKind.autosave);
    final h = hub.head(space)!.manifest['world/level.dat']!.h;
    expect(utf8.decode(hub.blobs[h]!), 'v1');
    expect(Directory('${tmp.path}/.minesync/outbox').existsSync(), isFalse);
    // il push successivo prende la modifica tarda
    final r2 = await engine().push(lock: await lock());
    expect(r2.generation!.n, 2);
    expect(
      utf8.decode(hub.blobs[hub.head(space)!.manifest['world/level.dat']!.h]!),
      'v2 dopo la foto',
    );
  });

  test('nessuna modifica: nessuna istantanea', () async {
    put('a.txt', '1');
    await engine().push(lock: await lock());
    expect(await engine().snapshot(), isNull);
    expect(await engine().pushSnapshot(lock: await lock()), isNull);
  });

  test('B-PUSH-22 blob sparito dall\'hub e file cambiato: istantanea scartata', () async {
    put('keep.txt', 'base');
    await engine().push(lock: await lock());
    final kh = hub.head(space)!.manifest['keep.txt']!.h;
    put('new.txt', 'nuovo');
    await engine().snapshot();
    hub.blobs.remove(kh); // come dopo una GC
    put('keep.txt', 'cambiato');
    await expectLater(
      engine().pushSnapshot(lock: await lock()),
      throwsA(isA<SyncException>().having((e) => e.kind, 'kind', SyncErrorKind.snapshotStale)),
    );
    expect(hub.head(space)!.n, 1);
  });

  test('blob sparito dall\'hub ma file uguale: si ricarica dal file vivo', () async {
    put('keep.txt', 'base');
    await engine().push(lock: await lock());
    final kh = hub.head(space)!.manifest['keep.txt']!.h;
    put('new.txt', 'nuovo');
    await engine().snapshot();
    hub.blobs.remove(kh);
    final r = await engine().pushSnapshot(lock: await lock());
    expect(r!.generation!.n, 2);
    expect(hub.blobs.containsKey(kh), isTrue);
  });

  test('istantanea vecchia rispetto all\'hub: scartata come base superata', () async {
    put('a.txt', '1');
    await engine().push(lock: await lock());
    put('a.txt', '2');
    await engine().snapshot();
    hub.commitDirect(space, {'a.txt': utf8.encode('di bob')});
    await expectLater(
      engine().pushSnapshot(lock: await lock()),
      throwsA(isA<SyncException>().having((e) => e.kind, 'kind', SyncErrorKind.staleBase)),
    );
    expect(LocalState(tmp.path).loadPending(space), isNull);
  });

  test('B-SCAN-08 attesa di quiete: una scrittura tardiva allunga l\'attesa', () async {
    put('a', '1');
    final ex = Exclusions(minecraftExclusions);
    unawaited(Future<void>.delayed(const Duration(milliseconds: 300), () => put('b', 'tardi')));
    final sw = Stopwatch()..start();
    expect(
      await waitQuiet(
        tmp.path,
        ex,
        stable: const Duration(milliseconds: 500),
        poll: const Duration(milliseconds: 50),
      ),
      isTrue,
    );
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(750));
    // una cartella che non si ferma mai: false al limite
    final t = Timer.periodic(const Duration(milliseconds: 40), (i) => put('c', '${i.tick}'));
    addTearDown(t.cancel);
    expect(
      await waitQuiet(
        tmp.path,
        ex,
        stable: const Duration(milliseconds: 300),
        cap: const Duration(milliseconds: 900),
        poll: const Duration(milliseconds: 50),
      ),
      isFalse,
    );
  });

  test('B-PUSH-24 limite di banda rispettato, 0 = nessun limite', () async {
    final data = List.generate(20, (_) => List.filled(10000, 1));
    var sw = Stopwatch()..start();
    await throttle(Stream.fromIterable(data), 0).drain<void>();
    expect(sw.elapsedMilliseconds, lessThan(200));
    sw = Stopwatch()..start();
    await throttle(Stream.fromIterable(data), 400000).drain<void>(); // 200 kB a 400 kB/s
    expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(200));
    expect(sw.elapsedMilliseconds, lessThan(1500));
  });
}
