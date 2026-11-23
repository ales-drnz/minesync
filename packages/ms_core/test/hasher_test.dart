import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

Uint8List randomBytes(int n, int seed) {
  final r = Random(seed);
  return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
}

String ref(List<int> b) => crypto.sha256.convert(b).toString();

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('ms_core_hash'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('backend nativo disponibile su questa piattaforma', () {
    expect(backend.isNative, isTrue, reason: backend.detail);
  });

  test('sha256Hex uguale a package:crypto', () {
    for (final n in [0, 1, 63, 64, 65, 1 << 20, (1 << 20) + 7]) {
      final d = randomBytes(n, n);
      expect(sha256Hex(d), ref(d), reason: 'n=$n');
    }
  });

  test('file piccolo: hash unico, niente chunk', () {
    final d = randomBytes(300000, 1);
    final f = File('${tmp.path}/a')..writeAsBytesSync(d);
    final r = hashFileSync(f.path);
    expect(r.size, d.length);
    expect(r.h, ref(d));
    expect(r.chunks, isNull);
  });

  test('file grande: chunk coerenti con il chunker e con i byte', () {
    final d = randomBytes(9 * 1024 * 1024 + 123, 2);
    final f = File('${tmp.path}/r.mca')..writeAsBytesSync(d);
    final r = hashFileSync(f.path);
    expect(r.h, ref(d));
    final cuts = chunkBoundaries(d);
    expect(r.chunks!.length, cuts.length);
    var start = 0;
    for (var i = 0; i < cuts.length; i++) {
      final c = r.chunks![i];
      expect(c.size, cuts[i] - start);
      expect(c.h, ref(d.sublist(start, cuts[i])));
      expect(c.size, lessThanOrEqualTo(chunkMax));
      if (i < cuts.length - 1) expect(c.size, greaterThanOrEqualTo(chunkMin));
      start = cuts[i];
    }
    // la voce del manifest accetta il risultato così com'è
    FileEntry(size: r.size, h: r.h, chunks: r.chunks);
  });

  test('una modifica locale cambia solo i chunk vicini', () {
    final d = randomBytes(16 * 1024 * 1024, 3);
    final a = File('${tmp.path}/a')..writeAsBytesSync(d);
    final e = Uint8List.fromList(d);
    for (var i = 0; i < 4096; i++) {
      e[8 * 1024 * 1024 + i] ^= 0xff;
    }
    final b = File('${tmp.path}/b')..writeAsBytesSync(e);
    final ca = hashFileSync(a.path).chunks!.map((c) => c.h).toSet();
    final cb = hashFileSync(b.path).chunks!.map((c) => c.h).toList();
    final changed = cb.where((h) => !ca.contains(h)).length;
    expect(changed, lessThanOrEqualTo(2), reason: '${cb.length} chunk');
  });

  test('un inserimento all\'inizio non sposta tutti i confini', () {
    final d = randomBytes(12 * 1024 * 1024, 4);
    final e = Uint8List.fromList([...randomBytes(1000, 5), ...d]);
    final a = chunkBoundaries(d).toSet();
    final shifted = chunkBoundaries(e).map((x) => x - 1000).toSet();
    expect(a.intersection(shifted).length, greaterThan(a.length - 3));
  });

  test('gear table: valori fissi del protocollo', () {
    expect(gearTable.length, 256);
    expect(gearTable.toSet().length, 256);
    // fissati: se cambiano, la deduplica tra versioni si rompe
    expect(gearTable[0].toUnsigned(64).toRadixString(16), '739761c54234a879');
    expect(gearTable[255].toUnsigned(64).toRadixString(16), '5fe50310ded59fb8');
    expect(chunkBoundaries(randomBytes(4 << 20, 42)), _golden42);
  });

  test('pool: stessi risultati, in parallelo, errori riportati', () async {
    final pool = HashPool.spawn(3);
    addTearDown(pool.close);
    final files = <File, Uint8List>{};
    for (var i = 0; i < 8; i++) {
      final d = randomBytes(i.isEven ? 50000 : 3 * 1024 * 1024, 10 + i);
      files[File('${tmp.path}/f$i')..writeAsBytesSync(d)] = d;
    }
    final results = await Future.wait(files.keys.map((f) => pool.file(f.path)));
    var i = 0;
    for (final d in files.values) {
      expect(results[i++].h, ref(d));
    }
    expect(await pool.bytes(randomBytes(10, 1)), ref(randomBytes(10, 1)));
    await expectLater(pool.file('${tmp.path}/manca'), throwsA(isA<FileSystemException>()));
  });
}

// Confini del chunker su 4 MiB di dati Random(42): fissati alla prima
// esecuzione, proteggono i parametri del protocollo.
const _golden42 = <int>[531085, 1067092, 1660539, 2236283, 2789551, 3337394, 4194304];
