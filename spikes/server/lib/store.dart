// Store dei blob content-addressed (SHA-256) e scrittura atomica dei file.
//
// Layout (come la 3.x):  <root>/blobs/<hh>/<hash>   <root>/tmp/.up-*
//                        <root>/manifests/<push>.json
// Il temporaneo sta sullo stesso filesystem della destinazione (stessa
// <root>), così il rename è atomico. Sequenza di ogni scrittura:
//   temporaneo -> scrittura -> fsync(file) -> close -> rename -> fsync(dir)
// All'avvio <root>/tmp viene svuotata: un crash a metà scrittura lascia solo
// temporanei, mai un blob con il nome definitivo e il contenuto parziale.
import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'fsync.dart';
import 'hasher.dart';

final _hexRe = RegExp(r'^[0-9a-f]{64}$');
bool validHash(String h) => _hexRe.hasMatch(h);

class HashMismatch implements Exception {
  HashMismatch(this.got);
  final String got;
}

class BlobStore {
  BlobStore(this.root, this.pool);
  final String root;
  final HashPool pool;
  final _rnd = Random.secure();

  String get _tmpDir => '$root/tmp';
  String blobPath(String h) => '$root/blobs/${h.substring(0, 2)}/$h';

  /// Prepara le directory e ripulisce i temporanei lasciati da un crash.
  /// Ritorna quanti temporanei sono stati rimossi.
  Future<int> open() async {
    for (final d in ['blobs', 'tmp', 'manifests']) {
      await Directory('$root/$d').create(recursive: true);
    }
    var n = 0;
    await for (final e in Directory(_tmpDir).list()) {
      await e.delete(recursive: true);
      n++;
    }
    // anche i temporanei dei file piccoli (manifest) accanto alla destinazione
    await for (final e in Directory('$root/manifests').list()) {
      if (e.path.split('/').last.startsWith('.tmp-')) {
        await e.delete();
        n++;
      }
    }
    return n;
  }

  String _tmpName(String dir) =>
      '$dir/.up-${DateTime.now().microsecondsSinceEpoch}-${_rnd.nextInt(1 << 32).toRadixString(16)}';

  bool has(String h) => File(blobPath(h)).existsSync();

  /// Scrive il blob [hash] leggendo [body] in streaming. Ritorna i byte scritti
  /// (o -1 se il blob c'era già: il corpo viene scartato senza scrivere).
  /// Su errore dello stream (client caduto) o hash diverso il temporaneo
  /// viene rimosso e la destinazione non viene mai toccata.
  ///
  /// Memoria per upload: HashJob.slots x HashJob.slotSize (32 x 256 KiB) di
  /// memoria nativa, riusata; il socket resta in pausa finché non ci sono
  /// abbastanza slot liberi (scritti su disco E digeriti dal worker).
  Future<int> putBlob(String hash, Stream<Uint8List> body) async {
    if (has(hash)) {
      await body.drain<void>();
      return -1;
    }
    final tmp = _tmpName(_tmpDir);
    final raf = await File(tmp).open(mode: FileMode.writeOnly);
    final job = pool.begin();
    var size = 0;
    var ok = false;
    Object? writeErr;
    Future<void> writes = Future.value();
    try {
      const cap = HashJob.slotSize;
      var slot = await job.acquire();
      var view = job.view(slot, cap);
      var fill = 0;
      void emit() {
        final s = slot, n = fill;
        job.submit(s, n); // il worker digerisce mentre il thread di I/O scrive
        final v = job.view(s, n);
        // scritture in ordine, una alla volta (RandomAccessFile non ne
        // accetta due in parallelo)
        writes = writes.then((_) async {
          if (writeErr == null) {
            try {
              await raf.writeFrom(v);
            } catch (e) {
              writeErr = e;
            }
          }
          job.writeDone(s);
        });
        size += n;
      }

      var maxc = 0, nc = 0;
      await for (final chunk in body) {
        var off = 0;
        while (off < chunk.length) {
          final n = min(cap - fill, chunk.length - off);
          view.setRange(fill, fill + n, chunk, off);
          fill += n;
          off += n;
          if (fill == cap) {
            emit();
            // di norma lo slot è già libero (riservato sotto): nessuna attesa,
            // il pezzo viene copiato tutto nello stesso turno dell'event loop
            slot = job.tryAcquire() ?? await job.acquire();
            if (writeErr != null) throw writeErr!;
            view = job.view(slot, cap);
            fill = 0;
          }
        }
        // backpressure QUI, a pezzo già consumato: il socket resta in pausa
        // finché non c'è posto per il pezzo successivo
        await job.reserve(HashJob.reserveSlots);
        if (writeErr != null) throw writeErr!;
      }
      if (fill > 0) emit();
      stderr.writeln('chunks $nc max $maxc');
      await writes;
      if (writeErr != null) throw writeErr!;
      final got = await job.close();
      if (pool.mode != HashMode.none && got != hash) throw HashMismatch(got);
      await raf.flush(); // = fsync(2) del file (thread di I/O del VM)
      await raf.close();
      final dst = blobPath(hash);
      final dstDir = Directory(dst.substring(0, dst.lastIndexOf('/')));
      if (!dstDir.existsSync()) {
        await dstDir.create();
        await fsyncDir('$root/blobs'); // la nuova directory <hh> è durevole
      }
      await File(tmp).rename(dst);
      ok = true;
      await fsyncDir(dstDir.path); // il rename è durevole
      return size;
    } finally {
      if (!ok) {
        await writes; // nessuna scrittura in volo sul file che chiudiamo
        job.abort();
        try {
          await raf.close();
        } catch (_) {}
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    }
  }

  /// Scrittura atomica e durevole di un file piccolo (manifest, impostazioni).
  Future<void> writeFileAtomic(String path, List<int> data) async {
    final dir = path.substring(0, path.lastIndexOf('/'));
    final tmp = '$dir/.tmp-${_rnd.nextInt(1 << 32).toRadixString(16)}';
    final raf = await File(tmp).open(mode: FileMode.writeOnly);
    var ok = false;
    try {
      await raf.writeFrom(data);
      await raf.flush();
      await raf.close();
      await File(tmp).rename(path);
      ok = true;
      await fsyncDir(dir);
    } finally {
      if (!ok) {
        try {
          await raf.close();
        } catch (_) {}
        try {
          await File(tmp).delete();
        } catch (_) {}
      }
    }
  }
}
