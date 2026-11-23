// Robustezza su disco: scritture atomiche, crash, riavvii, upload grandi in
// streaming e limite di upload paralleli (ATOMIC, G-01, B-GEN-16).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support.dart';

String hashOf(List<int> b) => sha256Hex(Uint8List.fromList(b));

/// Verifica che lo stato su disco di [t] sia coerente: testa leggibile e uguale
/// alla generazione più alta, ogni generazione valida, ogni blob presente e
/// con il contenuto giusto, tmp/ vuota.
Future<void> checkConsistent(TestHub t) async {
  expect(Directory('${t.data}/tmp').listSync(), isEmpty);
  for (final s in t.store.listSpaces()) {
    final head = await t.head(s.id);
    final hj = jsonDecode(File('${t.data}/spaces/${s.id}/head.json').readAsStringSync()) as Map;
    expect(hj['n'], head.n);
    expect(hj['digest'], head.digest);
    final gens = Directory(
      '${t.data}/spaces/${s.id}/generations',
    ).listSync().whereType<File>().where((f) => f.path.endsWith('.json')).toList();
    for (final f in gens) {
      final g = Generation.fromJson(jsonDecode(f.readAsStringSync()));
      expect(g.manifest.digest(), g.digest);
      expect(g.n, lessThanOrEqualTo(head.n));
      for (final h in g.manifest.blobs) {
        final b = File(t.store.blobs.pathOf(h));
        expect(b.existsSync(), isTrue, reason: 'blob $h della generazione ${g.n}');
        expect(hashOf(b.readAsBytesSync()), h);
      }
    }
  }
}

void main() {
  group('restart', () {
    late TestHub t;
    late String space;
    setUp(() async {
      t = await TestHub.start();
      space = await t.createSpace('World A');
    });
    tearDown(() => t.close());

    test(
      'lock e push aperti sopravvivono a un riavvio; l\'upload riprende e il commit passa',
      () async {
        final tok = await t.lock(space);
        final a = bytes('primo'), b = bytes('secondo');
        final r = await t.req(
          'POST',
          '/spaces/$space/pushes',
          body: PushBegin(
            parent: 0,
            parentDigest: emptyDigest,
            lockToken: tok,
            manifest: manifestOf({'a': a, 'b': b}),
          ).toJson(),
        );
        final pid = r.obj['pushId']! as String;
        await t.req('PUT', '/pushes/$pid/blobs/${hashOf(a)}', raw: a);
        await t.restart();
        expect(t.store.openPushes, 1);
        expect(t.store.lockSnapshot(space)!.name, 'alice');
        expect((await t.req('POST', '/pushes/$pid/commit')).code, 'push_incomplete');
        await t.req('PUT', '/pushes/$pid/blobs/${hashOf(b)}', raw: b);
        final c = await t.req('POST', '/pushes/$pid/commit');
        expect(c.status, 200);
        expect(c.obj['n'], 1);
      },
    );

    test(
      'B-GEN-16 head.json illeggibile o incoerente: ricostruito dalla generazione valida più alta',
      () async {
        for (var i = 0; i < 3; i++) {
          await t.push(space, {'a': bytes('$i')});
        }
        final headFile = File('${t.data}/spaces/$space/head.json');
        for (final bad in <List<int>>[
          [],
          bytes('spazzatura'),
          [0, 0, 0, 0],
          bytes('{"n": 99, "digest": "${'0' * 64}"}'),
          bytes('{"n": 2, "digest": "${'0' * 64}"}'),
        ]) {
          headFile.writeAsBytesSync(bad);
          await t.restart();
          expect((await t.head(space)).n, 3, reason: utf8.decode(bad, allowMalformed: true));
          final hj = jsonDecode(headFile.readAsStringSync()) as Map;
          expect(hj['n'], 3, reason: 'riscritto su disco');
        }
        // la generazione più alta è illeggibile: si torna a quella prima
        headFile.writeAsStringSync('');
        File('${t.data}/spaces/$space/generations/3.json').writeAsStringSync('{"n": 3');
        await t.restart();
        expect((await t.head(space)).n, 2);
        expect(t.logs.any((l) => l.contains('ricostruita')), isTrue);
        // il file illeggibile è messo da parte e il prossimo commit è il 3
        expect(File('${t.data}/spaces/$space/generations/3.json.orphan').existsSync(), isTrue);
        final p = await t.push(space, {'a': bytes('dopo')});
        expect(p.obj['n'], 3);
      },
    );

    test('B-ATOMIC-01 una scrittura fallita lascia la testa vecchia e nessun temporaneo', () async {
      await t.push(space, {'a': bytes('1')});
      final gens = Directory('${t.data}/spaces/$space/generations');
      Process.runSync('chmod', ['0500', gens.path]);
      addTearDown(() => Process.runSync('chmod', ['0700', gens.path]));
      final r = await t.push(space, {'a': bytes('2')});
      expect(r.status, 500);
      Process.runSync('chmod', ['0700', gens.path]);
      expect((await t.head(space)).n, 1);
      expect(gens.listSync().map((e) => e.uri.pathSegments.last), ['1.json']);
      // il push si può ritentare
      final again = await t.req('POST', '/pushes/${t.lastPush}/commit');
      expect(again.obj['n'], 2);
    }, testOn: 'linux || mac-os');

    test('B-ATOMIC-02 cancellare uno spazio con upload in corso non lo ricrea', () async {
      final tok = await t.lock(space);
      final big = noise(3 << 20);
      final r = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: 0,
          parentDigest: emptyDigest,
          lockToken: tok,
          manifest: manifestOf({'big': big}),
        ).toJson(),
      );
      final pid = r.obj['pushId']! as String;
      final ctrl = StreamController<List<int>>();
      final upload = t.req(
        'PUT',
        '/pushes/$pid/blobs/${hashOf(big)}',
        stream: ctrl.stream,
        contentLength: big.length,
      );
      ctrl.add(big.sublist(0, 1 << 20));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      t.clock.advance(const Duration(seconds: 91));
      expect((await t.req('DELETE', '/spaces/$space', as: 'carol')).status, 200);
      ctrl.add(big.sublist(1 << 20));
      await ctrl.close();
      final u = await upload;
      expect(u.status, anyOf(200, 201, 404, 410));
      expect(Directory('${t.data}/spaces/$space').existsSync(), isFalse);
      expect((await t.req('POST', '/pushes/$pid/commit')).status, anyOf(404, 410));
    });

    test(
      'B-ATOMIC-03 all\'avvio: cartelle senza descrittore saltate, cancellazioni completate',
      () async {
        Directory('${t.data}/spaces/orfana/generations').createSync(recursive: true);
        Directory('${t.data}/spaces/.deleted-vecchio-1234/generations').createSync(recursive: true);
        File('${t.data}/spaces/.deleted-vecchio-1234/space.json').writeAsStringSync('{}');
        await t.restart();
        expect([for (final s in t.store.listSpaces()) s.id], [space]);
        expect(Directory('${t.data}/spaces/.deleted-vecchio-1234').existsSync(), isFalse);
      },
    );

    test('G-01 crash simulato: temporanei, upload a metà e generazione oltre la testa', () async {
      await t.push(space, {'a': bytes('1')});
      final tok = t.tokens['$space/alice']!;
      final h = await t.head(space);
      final next = bytes('2');
      final b = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: h.n,
          parentDigest: h.digest,
          lockToken: tok,
          manifest: manifestOf({'a': next}),
        ).toJson(),
      );
      final pid = b.obj['pushId']! as String;
      await t.req('PUT', '/pushes/$pid/blobs/${hashOf(next)}', raw: next);
      await t.hub.close();
      // quello che resterebbe da un kill a metà commit: la generazione 2
      // scritta, la testa ancora a 1, temporanei di writeAtomic e un upload
      final gen2 = Generation(
        GenerationSummary(
          n: 2,
          parent: 1,
          digest: manifestOf({'a': next}).digest(),
          authorId: alice.id,
          author: 'alice',
          message: '',
          ts: 0,
          kind: GenerationKind.push,
          stats: const GenerationStats(files: 1, size: 1),
        ),
        manifestOf({'a': next}),
      );
      final gdir = '${t.data}/spaces/$space/generations';
      File('$gdir/2.json').writeAsStringSync(jsonEncode(gen2.toJson()));
      File('$gdir/3.json.x1$partSuffix').writeAsStringSync('{"n": 3, "par');
      File('${t.data}/spaces/$space/head.json.x2$partSuffix').writeAsStringSync('');
      File('${t.data}/pushes/abc.json.x3$partSuffix').writeAsStringSync('{');
      File('${t.data}/settings.json.x4$partSuffix').writeAsStringSync('{');
      File('${t.data}/tmp/${'e' * 64}.zz.up').writeAsBytesSync(noise(1000));
      await t.restart();
      final parts = Directory(t.data)
          .listSync(recursive: true)
          .map((e) => e.path.substring(t.data.length))
          .where((p) => p.endsWith(partSuffix) || p.startsWith('/tmp/'));
      expect(parts, isEmpty);
      expect((await t.head(space)).n, 1);
      expect(File('$gdir/2.json').existsSync(), isFalse);
      // il commit non risposto si ritenta e crea la generazione 2
      final c = await t.req('POST', '/pushes/$pid/commit');
      expect(c.status, 200);
      expect(c.obj['n'], 2);
      await checkConsistent(t);
    });

    test('G-01 crash dopo lo spostamento della testa: il ritentativo è un replay', () async {
      final c1 = await t.push(space, {'a': bytes('1')});
      final pid = t.lastPush!;
      await t.hub.close();
      // la sessione su disco è ancora "aperta" come se il crash fosse
      // arrivato prima di segnarla committata
      final f = File('${t.data}/pushes/$pid.json');
      final j = jsonDecode(f.readAsStringSync()) as Map<String, Object?>;
      j
        ..['status'] = 'open'
        ..['manifest'] = manifestOf({'a': bytes('1')}).toJson()
        ..remove('result');
      f.writeAsStringSync(jsonEncode(j));
      await t.restart();
      final c2 = await t.req('POST', '/pushes/$pid/commit');
      expect(c2.status, 200);
      expect(c2.obj['replay'], true);
      expect(c2.obj['n'], c1.obj['n']);
      expect((await t.head(space)).n, 1);
    });
  });

  group('upload', () {
    test('blob da 200 MiB generato al volo: in streaming, senza tenerlo in memoria', () async {
      final t = await TestHub.start();
      addTearDown(t.close);
      final space = await t.createSpace('Big');
      const size = 200 << 20;
      const piece = 1 << 20;
      // hash calcolato mentre si genera, senza mai avere il blob intero
      final ctx = backend.newCtx();
      for (var i = 0; i < size ~/ piece; i++) {
        ctx.update(noise(piece, i));
      }
      final h = hex(ctx.finish());
      ctx.dispose();
      final tok = await t.lock(space);
      final b = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: 0,
          parentDigest: emptyDigest,
          lockToken: tok,
          manifest: Manifest({'big.bin': FileEntry(size: size, h: h)}),
        ).toJson(),
      );
      final pid = b.obj['pushId']! as String;
      final rss0 = ProcessInfo.currentRss;
      var peak = rss0;
      final sampler = Timer.periodic(const Duration(milliseconds: 20), (_) {
        peak = max(peak, ProcessInfo.currentRss);
      });
      Stream<List<int>> gen() async* {
        for (var i = 0; i < size ~/ piece; i++) {
          yield noise(piece, i);
        }
      }

      final up = await t.req('PUT', '/pushes/$pid/blobs/$h', stream: gen(), contentLength: size);
      sampler.cancel();
      expect(up.status, 201, reason: '$up');
      expect(File(t.store.blobs.pathOf(h)).lengthSync(), size);
      // client e hub stanno nello stesso processo: la crescita resta molto
      // sotto la dimensione del blob
      expect(
        peak - rss0,
        lessThan(120 << 20),
        reason: 'RSS cresciuta di ${(peak - rss0) >> 20} MiB',
      );
      expect((await t.req('POST', '/pushes/$pid/commit')).status, 200);
      // e si rilegge in streaming con lo stesso hash
      final r = await t.client('alice').getUrl(t.uri('/blobs/$h'));
      final res = await r.close();
      final c2 = backend.newCtx();
      var n = 0;
      await for (final c in res) {
        c2.update(Uint8List.fromList(c));
        n += c.length;
      }
      expect(n, size);
      expect(hex(c2.finish()), h);
      c2.dispose();
    });

    test('al più MINESYNC_MAX_UPLOADS upload leggono il corpo; gli altri in coda', () async {
      final t = await TestHub.start(
        config: (d) => HubConfig(
          dataDir: d,
          address: InternetAddress.loopbackIPv4,
          port: 0,
          admins: const ['carol'],
          maxUploads: 2,
        ),
      );
      addTearDown(t.close);
      final space = await t.createSpace('Gate');
      final blobs = [for (var i = 0; i < 5; i++) noise(64 << 10, i + 10)];
      final tok = await t.lock(space);
      final b = await t.req(
        'POST',
        '/spaces/$space/pushes',
        body: PushBegin(
          parent: 0,
          parentDigest: emptyDigest,
          lockToken: tok,
          manifest: manifestOf({for (var i = 0; i < 5; i++) 'f$i': blobs[i]}),
        ).toJson(),
      );
      final pid = b.obj['pushId']! as String;
      final ctrls = [for (var i = 0; i < 5; i++) StreamController<List<int>>()];
      final ups = [
        for (var i = 0; i < 5; i++)
          t.req(
            'PUT',
            '/pushes/$pid/blobs/${hashOf(blobs[i])}',
            stream: ctrls[i].stream,
            contentLength: blobs[i].length,
          ),
      ];
      for (var i = 0; i < 5; i++) {
        ctrls[i].add(blobs[i].sublist(0, 100));
      }
      final gate = t.store.blobs.uploads;
      await eventually(() => gate.active == 2 && gate.queued == 3);
      for (var i = 0; i < 5; i++) {
        ctrls[i].add(blobs[i].sublist(100));
        await ctrls[i].close();
      }
      final rs = await Future.wait(ups);
      expect(rs.map((r) => r.status), everyElement(201));
      expect(gate.active, 0);
      expect((await t.req('POST', '/pushes/$pid/commit')).status, 200);
    });
  });

  test('bin/hub.dart: SIGTERM spegne in modo pulito (uscita 0)', () async {
    final dir = await Directory.systemTemp.createTemp('minesync-hub-term-');
    addTearDown(() => dir.delete(recursive: true));
    final p = await Process.start(
      Platform.resolvedExecutable,
      ['bin/hub.dart'],
      environment: {'MINESYNC_DATA': dir.path, 'MINESYNC_ADDR': '127.0.0.1:0'},
    );
    final lines = <String>[];
    final ready = Completer<void>();
    p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
      lines.add(l);
      if (l.contains('in ascolto') && !ready.isCompleted) ready.complete();
    });
    p.stdout.drain<void>().ignore();
    await ready.future.timeout(const Duration(seconds: 60));
    p.kill(ProcessSignal.sigterm);
    expect(await p.exitCode.timeout(const Duration(seconds: 20)), 0);
    expect(lines.any((l) => l.contains('spegnimento')), isTrue);
  }, testOn: 'linux || mac-os');

  test('G-01 kill -9 di un hub vero durante i push: al riavvio tutto coerente', () async {
    final dir = await Directory.systemTemp.createTemp('minesync-hub-kill-');
    addTearDown(() => dir.delete(recursive: true));
    final env = {
      'MINESYNC_DATA': dir.path,
      'MINESYNC_ADDR': '127.0.0.1:0',
      'MINESYNC_DEV_USER': 'alice',
      'MINESYNC_ADMINS': 'alice',
      'MINESYNC_MIN_FREE': '1',
    };
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final rng = Random(7);
    var generations = 0;
    for (var round = 0; round < 3; round++) {
      final p = await Process.start(Platform.resolvedExecutable, [
        'bin/hub.dart',
      ], environment: env);
      final port = Completer<int>();
      p.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen((l) {
        final m = RegExp(r'in ascolto su .*:(\d+),').firstMatch(l);
        if (m != null && !port.isCompleted) port.complete(int.parse(m[1]!));
      });
      p.stdout.drain<void>().ignore();
      final base =
          'http://127.0.0.1:${await port.future.timeout(const Duration(seconds: 60))}/api/v1';
      Future<Map<String, Object?>> call(
        String method,
        String path, [
        Object? body,
        List<int>? raw,
      ]) async {
        final r = await client.openUrl(method, Uri.parse('$base$path'));
        r.headers.set(csrfHeader, '1');
        if (body != null) r.add(utf8.encode(jsonEncode(body)));
        if (raw != null) r.add(raw);
        final res = await r.close();
        final s = await utf8.decoder.bind(res).join();
        return {'status': res.statusCode, if (s.isNotEmpty) 'body': jsonDecode(s)};
      }

      if (round == 0) {
        await call('POST', '/spaces', {'name': 'Kill'});
      }
      // forza il lock (anche quello del giro precedente, sopravvissuto al kill)
      final l = await call('POST', '/spaces/kill/lock', {'force': true});
      final tok = (l['body']! as Map)['token'] as String;
      var stop = false;
      final pushing = () async {
        while (!stop) {
          final hd = (await call('GET', '/spaces/kill/generations/head'))['body']! as Map;
          final files = {
            for (var i = 0; i < 40; i++)
              'w/$i': noise(1000 + rng.nextInt(60000), rng.nextInt(1 << 30)),
          };
          final b = await call('POST', '/spaces/kill/pushes', {
            'parent': hd['n'],
            'parentDigest': hd['digest'],
            'lockToken': tok,
            'manifest': manifestOf(files).toJson(),
          });
          final body = b['body']! as Map;
          final byHash = {for (final f in files.values) hashOf(f): f};
          for (final h in (body['missing']! as List).cast<String>()) {
            await call('PUT', '/pushes/${body['pushId']}/blobs/$h', null, byHash[h]);
          }
          final c = await call('POST', '/pushes/${body['pushId']}/commit');
          if (c['status'] == 200) generations++;
        }
      }().catchError((Object _) {}); // il kill interrompe le richieste in volo
      await Future<void>.delayed(Duration(milliseconds: 400 + rng.nextInt(600)));
      p.kill(ProcessSignal.sigkill);
      await p.exitCode;
      stop = true;
      await pushing;
    }
    expect(generations, greaterThan(0));
    // riavvio in-process e verifica completa
    final t = await TestHub.start(dir: dir);
    await checkConsistent(t);
    expect((await t.head('kill')).n, greaterThan(0));
    await t.close(keepData: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
