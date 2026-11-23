// Chiamate del client (lock, storia, pulizia, mondo) contro l'hub finto: percorsi, query,
// corpi e decodifica delle risposte; ZIP scaricato in streaming su file.
import 'dart:io';

import 'package:ms_core/ms_core.dart';
import 'package:ms_core/testing/fake_hub.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

void main() {
  late FakeHub hub;
  late HubClient client;
  late Directory tmp;

  setUp(() async {
    hub = await FakeHub.start();
    client = HubClient(hub.uri, idleTimeout: const Duration(seconds: 2));
    tmp = Directory.systemTemp.createTempSync('ms_client');
  });

  tearDown(() async {
    client.close(force: true);
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  Map<String, Object?> ev(int seq, String type) => {
    'seq': seq,
    'ts': seq * 1000,
    'type': type,
    'space': 'survival',
  };

  test('eventi: pagine all\'indietro con before, filtri per spazio e tipi', () async {
    hub.stubs['GET events'] = (q, _) => {
      'events': [ev(41, 'push'), ev(40, 'lock')],
      'last': 90,
      'oldest': 3,
      'more': true,
    };
    final p = await client.eventsBefore(
      42,
      limit: 2,
      space: 'survival',
      types: const [EventType.push, EventType.lock],
    );
    expect(hub.stubbed.single.query, {
      'before': '42',
      'limit': '2',
      'space': 'survival',
      'types': 'push,lock',
    });
    expect([for (final e in p.events) e.seq], [41, 40]);
    expect(p.more, isTrue);
    expect(p.oldest, 3);
    expect(p.last, 90);

    hub.stubbed.clear();
    final a = await client.eventsAfter(7);
    expect(hub.stubbed.single.query, {'after': '7'});
    expect(a.events, hasLength(2));
    // la forma di sempre resta una lista
    expect(await client.events(), hasLength(2));
  });

  test('B-PORT prova della porta: risposta e rifiuti dell\'hub', () async {
    hub.stubs['POST spaces/survival/lock/port-check'] = (_, _) => {
      'state': 'pending',
      'port': 25565,
    };
    final c = await client.portCheck('survival');
    expect(c.state, PortState.pending);
    expect(c.port, 25565);
    hub.stubs['POST spaces/survival/lock/port-check'] = (_, _) =>
        throw const ApiError(ErrorCode.rateLimited, 'too soon');
    await expectLater(
      client.portCheck('survival'),
      throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.rateLimited)),
    );
  });

  test('B-GC-08 pulizia: anteprima e pulizia, globali e per spazio', () async {
    final preview = {
      'keep': 20,
      'spaces': [
        {'id': 'survival', 'name': 'Survival', 'now': 132, 'after': 20, 'bytes': 5 << 30},
      ],
      'now': 132,
      'after': 20,
      'bytes': 5 << 30,
    };
    hub.stubs['POST gc/preview'] = (_, _) => preview;
    hub.stubs['POST spaces/survival/gc/preview'] = (_, _) => preview;
    hub.stubs['POST gc'] = (_, _) => {'generations': 112, 'blobs': 900, 'bytes': 5 << 30};
    hub.stubs['POST spaces/survival/gc'] = (_, _) => {'generations': 1, 'blobs': 2, 'bytes': 3};

    final p = await client.gcPreview(keep: 20);
    expect(p.keep, 20);
    expect(p.spaces.single.after, 20);
    expect(p.bytes, 5 << 30);
    await client.gcPreview(
      space: 'survival',
      history: const HistorySettings(keepLast: 5, keepHours: 1, keepDays: 2),
    );
    final r = await client.gc(keep: 20);
    expect(r.generations, 112);
    expect((await client.gc(space: 'survival')).bytes, 3);
    expect(
      [for (final s in hub.stubbed) s.body],
      [
        {'keep': 20},
        {
          'history': {'keepLast': 5, 'keepHours': 1, 'keepDays': 2},
        },
        {'keep': 20},
        <String, Object?>{},
      ],
    );
  });

  test('uso del disco e mondo della HEAD', () async {
    hub.stubs['GET usage'] = (_, _) => {
      'disk': {'free': 10, 'total': 100, 'minFree': 1},
      'blobs': 50,
      'dl': 5,
      'spaces': {
        'survival': {
          'generations': 3,
          'logical': 90,
          'referenced': 40,
          'exclusive': 30,
          'computedAt': 1,
        },
      },
      'computedAt': 1,
    };
    hub.stubs['GET spaces/survival/world'] = (_, _) => {
      'n': 4,
      'chip': {'mcVersion': '1.21.1', 'loader': 'fabric', 'mods': 42},
      'modsBytes': 0,
      'players': 3,
      'icon': false,
    };
    final u = await client.usage();
    expect(u.spaces['survival']!.exclusive, 30);
    expect(u.blobs, 50);
    final w = await client.world('survival');
    expect(w.chip.loader, Loader.fabric);
    expect(w.chip.mods, 42);
  });

  test('B-GEN-12 B-GEN-15 differenze, file ripristinato, generazione eliminata', () async {
    hub.stubs['GET spaces/survival/generations/7/diff'] = (_, _) => {
      'n': 7,
      'parent': 6,
      'added': {
        'total': 1,
        'items': [
          {'path': 'world/a', 'size': 3},
        ],
      },
      'changed': {'total': 0, 'items': <Object?>[]},
      'removed': {'total': 0, 'items': <Object?>[]},
    };
    hub.stubs['POST spaces/survival/restore-file'] = (_, _) => {
      'n': 8,
      'parent': 7,
      'digest': '0' * 64,
      'authorId': 'a',
      'author': 'alice',
      'message': '',
      'ts': 1,
      'kind': 'restore',
      'stats': {'files': 1, 'size': 3, 'added': 0, 'changed': 1, 'removed': 0},
      'restoredFrom': 5,
      'restoredPath': 'world/region/r.0.0.mca',
    };
    hub.stubs['GET spaces/survival/generations/3/freed'] = (_, _) => {'n': 3, 'bytes': 1234};
    hub.stubs['DELETE spaces/survival/generations/3'] = (_, _) => {'deleted': 3, 'bytes': 1234};

    final d = await client.diff('survival', 7, limit: 50);
    expect(hub.stubbed.last.query, {'limit': '50'});
    expect(d.added.items.single.path, 'world/a');
    final g = await client.restoreFile(
      'survival',
      const RestoreFileRequest(path: 'world/region/r.0.0.mca', from: 5),
    );
    expect(hub.stubbed.last.body, {'path': 'world/region/r.0.0.mca', 'from': 5});
    expect(g.restoredPath, 'world/region/r.0.0.mca');
    expect(await client.freedBy('survival', 3), 1234);
    final del = await client.deleteGeneration('survival', 3);
    expect(del.deleted, 3);
    expect(del.bytes, 1234);
  });

  group('B-SPACE-03 ZIP', () {
    test('scaricato in streaming nel file, con l\'avanzamento', () async {
      final bytes = List<int>.generate(300000, (i) => i & 0xff);
      hub.stubs['GET spaces/survival/generations/head/zip'] = (_, _) =>
          FakeBytes(bytes, contentType: ContentType('application', 'zip'));
      final path = '${tmp.path}/survival.zip';
      int? lastGot;
      int? lastTotal;
      final n = await client.exportZip(
        'survival',
        path,
        onProgress: (got, total) {
          lastGot = got;
          lastTotal = total;
        },
      );
      expect(n, bytes.length);
      expect(lastGot, bytes.length);
      expect(lastTotal, bytes.length);
      expect(File(path).readAsBytesSync(), bytes);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('blob mancanti: errore dell\'hub, nessun file', () async {
      hub.stubs['GET spaces/survival/generations/3/zip'] = (_, _) =>
          throw const ApiError(ErrorCode.blobsMissing, 'missing');
      final path = '${tmp.path}/x.zip';
      await expectLater(
        client.exportZip('survival', path, n: 3),
        throwsA(isA<ApiError>().having((e) => e.code, 'code', ErrorCode.blobsMissing)),
      );
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.part').existsSync(), isFalse);
    });

    test('risposta troncata: niente file a metà', () async {
      hub.stubs['GET spaces/survival/generations/head/zip'] = (_, _) =>
          FakeBytes(List<int>.filled(1000, 1), declaredLength: 5000);
      final path = '${tmp.path}/short.zip';
      await expectLater(client.exportZip('survival', path), throwsA(isA<HubUnreachable>()));
      expect(File(path).existsSync(), isFalse);
      expect(File('$path.part').existsSync(), isFalse);
    });
  });
}
