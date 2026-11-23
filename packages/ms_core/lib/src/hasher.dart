// Hash dei file per il manifest: SHA-256 dell'intero file e, oltre la
// soglia, dei suoi chunk FastCDC, in una sola lettura. Gira in un pool di
// isolate con il backend nativo di ciascuno.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ms_protocol/ms_protocol.dart';

import 'chunker.dart';
import 'hash/backend.dart';

export 'hash/backend.dart' show Sha256Backend, backend, backendByName;

/// Esadecimale minuscolo di un digest.
String hex(Uint8List d) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in d) {
    out
      ..write(digits[b >> 4])
      ..write(digits[b & 15]);
  }
  return out.toString();
}

/// Risultato dell'hash di un file.
final class FileHash {
  const FileHash(this.size, this.h, this.chunks);

  /// Byte letti (la dimensione effettiva al momento della lettura).
  final int size;
  final String h;
  final List<Chunk>? chunks;
}

/// Contesti riusati dall'isolate corrente.
final Sha256Ctx _whole = backend.newCtx();
final Sha256Ctx _part = backend.newCtx();

/// SHA-256 di byte in memoria, sincrono.
String sha256Hex(Uint8List data) {
  _whole.update(data);
  return hex(_whole.finish());
}

/// Hash di un file, sincrono, sull'isolate corrente. Divide in chunk se il
/// file letto è di almeno [chunkThreshold] byte.
FileHash hashFileSync(String path) {
  final f = File(path).openSync();
  try {
    final expected = f.lengthSync();
    final chunked = expected >= chunkThreshold;
    final cdc = FastCdc();
    final chunks = <Chunk>[];
    final buf = _whole.buffer;
    var total = 0;
    while (true) {
      final n = f.readIntoSync(buf, 0, buf.length);
      if (n == 0) break;
      _whole.updateBuffer(n);
      total += n;
      if (chunked) {
        var pos = 0;
        while (pos < n) {
          final before = cdc.pending;
          final cut = cdc.scan(buf, pos, n);
          if (cut < 0) {
            _part.updateFrom(_whole, pos, n - pos);
            break;
          }
          _part.updateFrom(_whole, pos, cut - pos);
          chunks.add(Chunk(hex(_part.finish()), before + cut - pos));
          pos = cut;
        }
      }
    }
    if (chunked && cdc.pending > 0) {
      chunks.add(Chunk(hex(_part.finish()), cdc.pending));
    } else if (!chunked) {
      _part.finish();
    }
    final h = hex(_whole.finish());
    // Se il file è cambiato sotto i piedi e ora è sotto la soglia, i chunk
    // non servono (e la somma tornerebbe comunque).
    final useChunks = chunked && total >= chunkThreshold;
    return FileHash(total, h, useChunks ? chunks : null);
  } finally {
    f.closeSync();
  }
}

// --- Pool di isolate ---------------------------------------------------------

const _kFile = 0, _kBytes = 1;

final class _Job {
  _Job(this.msg);
  final List<Object?> msg;
  final completer = Completer<Object?>();
}

final class _Worker {
  _Worker(this.port);
  final SendPort port;
  int inflight = 0;
}

/// Pool di isolate per gli hash. Le richieste si accodano finché i worker
/// non sono pronti.
final class HashPool {
  HashPool._(this._rx, this._size);

  /// Job in volo per worker: 2 nasconde la latenza dei messaggi sui file
  /// piccoli.
  static const int depth = 2;

  static HashPool? _shared;

  /// Pool condiviso: un worker per core, al massimo 8 (oltre, il limite è
  /// il disco).
  static HashPool get shared =>
      _shared ??= HashPool.spawn(math.min(Platform.numberOfProcessors, 8));

  factory HashPool.spawn(int size) {
    final rx = ReceivePort();
    final pool = HashPool._(rx, size);
    rx.listen(pool._onMessage);
    for (var i = 0; i < size; i++) {
      pool._isolates.add(Isolate.spawn(_workerMain, rx.sendPort, debugName: 'hash-$i'));
    }
    return pool;
  }

  final ReceivePort _rx;
  final int _size;
  final _isolates = <Future<Isolate>>[];
  final _workers = <_Worker>[];
  final _queue = <_Job>[];
  final _pending = <int, (_Job, _Worker)>{};
  var _nextId = 0;
  var _closed = false;

  int get size => _size;

  /// Hash di un file (intero più chunk se grande).
  Future<FileHash> file(String path) async {
    final r = await _submit([_kFile, path]) as List<Object?>;
    final flat = r[2] as Int64List?;
    final hashes = r[3] as List<Object?>?;
    return FileHash(
      r[0] as int,
      r[1] as String,
      flat == null
          ? null
          : [for (var i = 0; i < flat.length; i++) Chunk(hashes![i] as String, flat[i])],
    );
  }

  /// SHA-256 di byte in memoria (sotto 1 MiB conviene [sha256Hex]).
  Future<String> bytes(Uint8List data) async =>
      await _submit([
            _kBytes,
            TransferableTypedData.fromList([data]),
          ])
          as String;

  Future<Object?> _submit(List<Object?> body) {
    if (_closed) throw StateError('pool chiuso');
    final job = _Job(body);
    _queue.add(job);
    _pump();
    return job.completer.future;
  }

  void _onMessage(Object? m) {
    if (m is SendPort) {
      _workers.add(_Worker(m));
      _pump();
      return;
    }
    final reply = m as List<Object?>;
    final (job, w) = _pending.remove(reply[0] as int)!;
    w.inflight--;
    final ok = reply[1] as bool;
    if (ok) {
      job.completer.complete(reply[2]);
    } else {
      final err = reply[2] as List<Object?>;
      job.completer.completeError(
        err[0] == 'fs'
            ? FileSystemException(err[1] as String, err[2] as String?)
            : StateError(err[1] as String),
      );
    }
    _pump();
  }

  void _pump() {
    while (_queue.isNotEmpty) {
      _Worker? best;
      for (final w in _workers) {
        if (w.inflight < depth && (best == null || w.inflight < best.inflight)) best = w;
      }
      if (best == null) return;
      final job = _queue.removeAt(0);
      final id = _nextId++;
      best.inflight++;
      _pending[id] = (job, best);
      best.port.send([id, ...job.msg]);
    }
  }

  Future<void> close() async {
    _closed = true;
    for (final iso in await Future.wait(_isolates)) {
      iso.kill(priority: Isolate.immediate);
    }
    _rx.close();
    for (final (job, _) in _pending.values) {
      job.completer.completeError(StateError('pool chiuso'));
    }
    if (identical(this, _shared)) _shared = null;
  }
}

void _workerMain(SendPort out) {
  final rx = RawReceivePort();
  rx.handler = (Object? raw) {
    final m = raw as List<Object?>;
    final id = m[0] as int;
    try {
      final Object? result;
      switch (m[1] as int) {
        case _kFile:
          final r = hashFileSync(m[2] as String);
          final c = r.chunks;
          result = [
            r.size,
            r.h,
            c == null ? null : Int64List.fromList([for (final k in c) k.size]),
            c == null ? null : [for (final k in c) k.h],
          ];
        case _kBytes:
          result = sha256Hex((m[2] as TransferableTypedData).materialize().asUint8List());
        default:
          throw StateError('job sconosciuto');
      }
      out.send([id, true, result]);
    } on FileSystemException catch (e) {
      out.send([
        id,
        false,
        ['fs', e.message, e.path],
      ]);
    } catch (e) {
      out.send([
        id,
        false,
        ['other', '$e', null],
      ]);
    }
  };
  out.send(rx.sendPort);
}
