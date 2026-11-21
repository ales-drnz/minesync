// Sonde puntuali sulle primitive di I/O di Dart (AOT):
//  1. File(dir).open() su una directory: funziona? (per l'fsync della directory)
//  2. RandomAccessFile.flush() fa davvero fsync? Lo si vede dal calo di
//     "Dirty" in /proc/meminfo e dal tempo che impiega.
//  3. fsync della directory via FFI.
//  4. throughput di SHA-256 di package:crypto (puro Dart) su questo host.
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:spike_server/fsync.dart';

int dirtyKb() {
  final l = File('/proc/meminfo')
      .readAsLinesSync()
      .firstWhere((l) => l.startsWith('Dirty:'));
  return int.parse(l.split(RegExp(r'\s+'))[1]);
}

Future<void> main(List<String> args) async {
  final dir = Directory(args.isNotEmpty ? args[0] : '.tmp/probe')
    ..createSync(recursive: true);

  // 1
  try {
    final raf = await File(dir.path).open();
    await raf.close();
    print('1. File(dir).open(): OK (inatteso)');
  } on FileSystemException catch (e) {
    print('1. File(dir).open(): FALLISCE -> ${e.osError?.message ?? e.message}');
  }

  // 2
  final f = File('${dir.path}/dirty.bin');
  final raf = await f.open(mode: FileMode.write);
  final buf = Uint8List(1 << 20);
  for (var i = 0; i < 512; i++) {
    await raf.writeFrom(buf);
  }
  final before = dirtyKb();
  final sw = Stopwatch()..start();
  await raf.flush();
  final ms = sw.elapsedMilliseconds;
  final after = dirtyKb();
  await raf.close();
  print('2. flush() di 512 MiB sporchi: ${ms} ms, Dirty ${before ~/ 1024} MiB -> ${after ~/ 1024} MiB');
  f.deleteSync();

  // 3
  final sw3 = Stopwatch()..start();
  final r = fsyncDirSync(dir.path);
  print('3. fsyncDirSync(${dir.path}) = $r in ${sw3.elapsedMicroseconds} us');
  await fsyncDir(dir.path);
  print('   fsyncDir (Isolate.run) OK');

  // 4
  final data = Uint8List(1 << 20);
  for (var i = 0; i < data.length; i++) {
    data[i] = i * 31;
  }
  final sw4 = Stopwatch()..start();
  final out = _Sink();
  final s = sha256.startChunkedConversion(out);
  for (var i = 0; i < 1024; i++) {
    s.add(data);
  }
  s.close();
  final sec = sw4.elapsedMicroseconds / 1e6;
  print('4. sha256 (package:crypto) 1 GiB: ${(1024 / sec).toStringAsFixed(0)} MiB/s');
}

class _Sink implements Sink<Digest> {
  Digest? d;
  @override
  void add(Digest data) => d = data;
  @override
  void close() {}
}
