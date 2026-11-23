// Store globale dei blob, indirizzati per SHA-256: blobs/<h[0:2]>/<h>.
//
// Un upload scorre in tmp/ calcolando l'hash mentre scrive, rifiuta i byte
// oltre la dimensione dichiarata e va al nome definitivo solo se hash e
// dimensione tornano. Il corpo non sta mai tutto in memoria: `await for`
// tiene in pausa il socket finché il pezzo corrente non è scritto, quindi in
// memoria c'è al più un pezzo (≤ ~6 MiB, misurato) per upload
// attivo, e gli upload attivi sono al più [maxUploads].
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'mutex.dart';

final class BlobStore {
  BlobStore(this.root, {int maxUploads = 4}) : uploads = Semaphore(maxUploads);

  final String root;

  /// Upload che leggono il corpo in parallelo; gli altri aspettano in coda
  /// senza leggere dal socket.
  final Semaphore uploads;

  final _rng = Random.secure();

  String get blobsDir => '$root/blobs';
  String get tmpDir => '$root/tmp';

  /// Percorso del blob [h] (già validato con [isHash]).
  String pathOf(String h) => '$blobsDir/${h.substring(0, 2)}/$h';

  /// Crea le cartelle e svuota tmp/ (upload interrotti da un crash).
  Future<int> open() async {
    await Directory(blobsDir).create(recursive: true);
    final tmp = Directory(tmpDir);
    var n = 0;
    if (await tmp.exists()) {
      await for (final e in tmp.list()) {
        await e.delete(recursive: true);
        n++;
      }
    } else {
      await tmp.create(recursive: true);
    }
    return n;
  }

  bool has(String h) => File(pathOf(h)).existsSync();

  /// Riceve il blob [h] di [size] byte da [body]. Lancia [ApiError]
  /// `too_large` al primo byte oltre [size], `bad_hash` se dimensione o
  /// hash non tornano; gli errori dello stream (client caduto) passano. In
  /// ogni caso di errore non resta niente su disco.
  Future<void> put(String h, int size, Stream<List<int>> body) async {
    final tmp = '$tmpDir/$h.${_rng.nextInt(1 << 32).toRadixString(36)}.up';
    final raf = await File(tmp).open(mode: FileMode.writeOnly);
    final ctx = backend.newCtx();
    var n = 0;
    var closed = false, ok = false;
    try {
      await for (final chunk in body) {
        n += chunk.length;
        if (n > size) {
          throw ApiError(
            ErrorCode.tooLarge,
            'blob $h: more bytes than the declared $size',
            details: {'size': size},
          );
        }
        final data = chunk is Uint8List ? chunk : Uint8List.fromList(chunk);
        ctx.update(data);
        await raf.writeFrom(data);
      }
      if (n != size) {
        throw ApiError(
          ErrorCode.badHash,
          'blob $h: got $n bytes, expected $size',
          details: {'size': size, 'got': n},
        );
      }
      final got = hex(ctx.finish());
      if (got != h) {
        throw ApiError(ErrorCode.badHash, 'blob $h: content hashes to $got', details: {'got': got});
      }
      await raf.flush(); // fsync(2) del file
      await raf.close();
      closed = true;
      final dir = Directory('$blobsDir/${h.substring(0, 2)}');
      if (!dir.existsSync()) {
        await dir.create();
        await fsyncDir(blobsDir); // la nuova cartella è durevole
      }
      await commitTemp(tmp, pathOf(h));
      ok = true;
    } finally {
      ctx.dispose();
      if (!closed) {
        try {
          await raf.close();
        } catch (_) {
          // già chiuso
        }
      }
      if (!ok) {
        try {
          await File(tmp).delete();
        } on FileSystemException {
          // già sparito
        }
      }
    }
  }

  /// Tutti i blob presenti.
  Future<Set<String>> list() async {
    final out = <String>{};
    await for (final d in Directory(blobsDir).list()) {
      if (d is! Directory) continue;
      await for (final f in d.list()) {
        final name = f.uri.pathSegments.last;
        if (f is File && isHash(name)) out.add(name);
      }
    }
    return out;
  }

  /// Cancella il blob [h], in modo sincrono (vedi la GC). Vero se c'era.
  bool deleteSync(String h) {
    try {
      File(pathOf(h)).deleteSync();
      return true;
    } on FileSystemException {
      return false;
    }
  }
}
