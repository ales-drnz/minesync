import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late HashPool pool;
  final ex = Exclusions(minecraftExclusions);

  setUpAll(() => pool = HashPool.spawn(2));
  tearDownAll(() => pool.close());
  setUp(() => root = Directory.systemTemp.createTempSync('ms_scan'));
  tearDown(() => root.deleteSync(recursive: true));

  File put(String rel, String content) => File('${root.path}/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  // data nel passato: fuori dalla finestra "racy"
  final past = DateTime.now().subtract(const Duration(minutes: 5));
  final later = past.add(const Duration(minutes: 1));

  Future<ScanResult> scan({HashCache? prior, List<String>? hashed}) => scanTree(
    root.path,
    ex,
    prior: prior,
    pool: pool,
    onFile: (rel, h) {
      if (h) hashed?.add(rel);
    },
  );

  test('manifest con esclusioni e hash corretti', () async {
    put('server.properties', 'motd=ciao');
    put('world/level.dat', 'L');
    put('logs/latest.log', 'rumore');
    put('world/session.lock', 'x');
    put('world/x.minesyncpart', 'mezzo download');
    final r = await scan();
    expect(r.manifest.files.keys, ['server.properties', 'world/level.dat']);
    expect(r.manifest['world/level.dat']!.h, crypto.sha256.convert(utf8.encode('L')).toString());
    expect(r.unreadable, isEmpty);
  });

  test('la cache evita di ri-leggere i file invariati', () async {
    put('a.txt', 'uno').setLastModifiedSync(past);
    put('b.txt', 'due').setLastModifiedSync(past);
    final first = await scan();
    final hashed = <String>[];
    put('b.txt', 'DUE').setLastModifiedSync(later);
    final second = await scan(prior: first.cache, hashed: hashed);
    expect(hashed, ['b.txt']);
    expect(second.manifest['b.txt']!.h, crypto.sha256.convert(utf8.encode('DUE')).toString());
  });

  test('un file appena modificato non si fida della cache al giro dopo', () async {
    put('a.txt', 'uno'); // mtime = adesso: racy
    final first = await scan();
    expect(first.cache.entries['a.txt']!.racy, isTrue);
    final hashed = <String>[];
    await scan(prior: first.cache, hashed: hashed);
    expect(hashed, ['a.txt']);
  });

  test('la cache sopravvive a salvataggio e lettura', () async {
    put('a.txt', 'uno').setLastModifiedSync(past);
    final first = await scan();
    final path = '${root.path}/.minesync/cache.json';
    Directory('${root.path}/.minesync').createSync();
    await first.cache.save(path);
    final hashed = <String>[];
    await scan(prior: HashCache.load(path), hashed: hashed);
    expect(hashed, isEmpty);
    expect(HashCache.load('${root.path}/manca.json').entries, isEmpty);
  });

  test('cartella .minesync mai scansionata', () async {
    put('.minesync/base.json', '{}');
    put('a', 'x');
    expect((await scan()).manifest.files.keys, ['a']);
  });

  test('nomi non portabili saltati e segnalati', () async {
    put('ok.txt', '1');
    put('what?.txt', '2');
    put('CON.txt', '3');
    final r = await scan();
    expect(r.manifest.files.keys, ['ok.txt']);
    expect(r.badNames, ['CON.txt', 'what?.txt']);
  }, testOn: '!windows');

  test('maiuscole diverse: si tiene il primo', () async {
    put('Mods/a.jar', '1');
    put('mods/a.jar', '2');
    final r = await scan();
    expect(r.manifest.files.keys, ['Mods/a.jar']);
    expect(r.caseDups, ['mods/a.jar']);
  }, testOn: 'linux');

  test('link a file seguito, link a cartella è un errore', () async {
    put('real/target.txt', 'dentro');
    Link('${root.path}/alias.txt').createSync('${root.path}/real/target.txt');
    var r = await scan();
    expect(r.manifest['alias.txt']!.h, r.manifest['real/target.txt']!.h);
    Link('${root.path}/worldlink').createSync('${root.path}/real');
    await expectLater(scan(), throwsA(isA<ScanException>()));
    // ma se la cartella collegata è esclusa, nessun problema
    Link('${root.path}/worldlink').deleteSync();
    Link('${root.path}/logs').createSync('${root.path}/real');
    r = await scan();
    expect(r.manifest.files.keys, contains('real/target.txt'));
  }, testOn: '!windows');

  test('bit di esecuzione', () async {
    put('run.sh', '#!/bin/sh');
    put('a.txt', 'x');
    await Process.run('chmod', ['+x', '${root.path}/run.sh']);
    final r = await scan();
    expect(r.manifest['run.sh']!.x, isTrue);
    expect(r.manifest['a.txt']!.x, isFalse);
  }, testOn: '!windows');

  test('file illeggibile saltato e segnalato', () async {
    put('ok.txt', '1');
    final f = put('secret.dat', '2');
    await Process.run('chmod', ['000', f.path]);
    addTearDown(() => Process.runSync('chmod', ['644', f.path]));
    final r = await scan();
    expect(r.manifest.files.keys, ['ok.txt']);
    expect(r.unreadable, ['secret.dat']);
    expect(r.skipped, contains('secret.dat'));
  }, testOn: '!windows');

  test('file grande: chunk nel manifest', () async {
    final f = File('${root.path}/world/region/r.0.0.mca')..createSync(recursive: true);
    f.writeAsBytesSync(List.generate(5 << 20, (i) => (i * 31 + (i >> 9)) & 0xff));
    final r = await scan();
    final e = r.manifest['world/region/r.0.0.mca']!;
    expect(e.chunks, isNotNull);
    expect(e.size, 5 << 20);
  });

  group('scritture atomiche', () {
    test('scrive, sostituisce e non lascia temporanei', () async {
      final p = '${root.path}/state.json';
      await writeAtomic(p, utf8.encode('uno'));
      await writeAtomic(p, utf8.encode('due'));
      writeAtomicSync(p, utf8.encode('tre'));
      expect(File(p).readAsStringSync(), 'tre');
      expect(root.listSync().map((e) => e.path).where((p) => p.endsWith(partSuffix)), isEmpty);
    });

    test('cartella inesistente: errore e niente file a metà', () async {
      await expectLater(writeAtomic('${root.path}/no/x', [1]), throwsA(isA<FileSystemException>()));
    });
  });
}
