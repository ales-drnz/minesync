// API pubblica dello spike: SHA-256 di byte, file e range di file, con
// backend nativo di sistema e pool di isolate per il parallelismo.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'src/backend.dart';

export 'src/backend.dart' show Sha256Backend, Sha256Ctx, backend, backendByName;

/// Blocco di lettura: 1 MiB, riusato (un buffer per isolate).
const readBlock = stageSize;

/// Hasher incrementale sul backend di questo isolate.
class Sha256Hasher {
  Sha256Hasher([Sha256Backend? b]) : _ctx = (b ?? backend).newCtx();
  final Sha256Ctx _ctx;
  bool _closed = false;

  void add(Uint8List data, [int start = 0, int? end]) {
    if (_closed) throw StateError('hasher già chiuso');
    _ctx.update(data, start, end);
  }

  /// Restituisce il digest e libera il contesto nativo.
  Uint8List close() {
    if (_closed) throw StateError('hasher già chiuso');
    _closed = true;
    final d = _ctx.finish();
    _ctx.dispose();
    return d;
  }
}

/// Contesto (con il suo buffer di staging) riusato dall'isolate corrente.
final _local = backend.newCtx();

Uint8List sha256BytesSync(Uint8List data) {
  _local.update(data);
  return _local.finish();
}

/// Hash di [length] byte da [offset] (tutto il file se length è null),
/// lettura sincrona a blocchi da 1 MiB direttamente nel buffer di staging
/// (nativo): nessuna copia oltre a quella kernel -> buffer.
Uint8List sha256FileSync(String path, {int offset = 0, int? length}) {
  final f = File(path).openSync();
  try {
    return _hashOpen(f, offset, length);
  } finally {
    f.closeSync();
  }
}

Uint8List _hashOpen(RandomAccessFile f, int offset, int? length) {
  f.setPositionSync(offset);
  var left = length ?? (1 << 62);
  while (left > 0) {
    final want = left < readBlock ? left : readBlock;
    final n = f.readIntoSync(_local.buffer, 0, want);
    if (n == 0) break;
    _local.updateBuffer(n);
    left -= n;
  }
  if (length != null && left > 0) throw FileSystemException('range oltre la fine del file', f.path);
  return _local.finish();
}

/// Hash di un file nel pool condiviso.
Future<Uint8List> sha256File(String path) => HashPool.shared.file(path);

/// Hash di byte in memoria: sotto 4 MiB in linea (il nativo impiega < 2 ms),
/// sopra nel pool per non bloccare l'isolate chiamante.
Future<Uint8List> sha256Bytes(Uint8List data) async {
  if (data.length < (4 << 20)) return sha256BytesSync(data);
  return HashPool.shared.bytes(data);
}

// --- Pool di isolate ---------------------------------------------------------

const _kFile = 0, _kRanges = 1, _kBytes = 2;

class _Job {
  _Job(this.msg);
  final List<Object?> msg;
  final completer = Completer<Object>();
}

class _Worker {
  _Worker(this.port);
  final SendPort port;
  int inflight = 0;
}

class HashPool {
  HashPool._(this._rx);

  /// Job in volo per worker: 2 nasconde la latenza dei messaggi sui file
  /// piccoli (un file da 512 KiB si hasha in ~0,25 ms).
  static const depth = 2;

  static HashPool? _shared;

  /// Pool di default: un worker per core, al massimo 8 (oltre, sul sync
  /// il collo di bottiglia diventa il disco).
  static HashPool get shared =>
      _shared ??= HashPool.spawn(math.min(Platform.numberOfProcessors, 8));

  final ReceivePort _rx;
  final _workers = <_Worker>[];
  final _queue = <_Job>[];
  final _pending = <int, (_Job, _Worker)>{};
  var _nextId = 0;
  Completer<void>? _ready;

  /// Avvia [size] worker. I job inviati prima che siano pronti restano in coda.
  factory HashPool.spawn(int size) {
    final rx = ReceivePort();
    final pool = HashPool._(rx);
    pool._ready = Completer<void>();
    rx.listen((m) {
      if (m is SendPort) {
        pool._workers.add(_Worker(m));
        if (pool._workers.length == size) pool._ready!.complete();
        pool._pump();
      } else {
        pool._onReply(m as List<Object?>);
      }
    });
    for (var i = 0; i < size; i++) {
      pool._spawning.add(Isolate.spawn(_workerMain, rx.sendPort, debugName: 'sha256-$i')
          .then((iso) => pool._spawned.add(iso)));
    }
    return pool;
  }
  final _spawning = <Future<void>>[];
  final _spawned = <Isolate>[];

  Future<void> get ready async {
    await Future.wait(_spawning);
    await _ready!.future;
  }

  int get size => _workers.length;

  Future<Uint8List> file(String path) async => await _submit([_kFile, path]) as Uint8List;

  /// Hash di più range dello stesso file in un solo job (i chunk di un
  /// region file): [ranges] = coppie offset, lunghezza.
  Future<List<Uint8List>> ranges(String path, Int64List ranges) async {
    final flat = await _submit([_kRanges, path, ranges]) as Uint8List;
    return [for (var i = 0; i < flat.length; i += 32) Uint8List.sublistView(flat, i, i + 32)];
  }

  /// Byte in memoria: TransferableTypedData evita la copia profonda del
  /// messaggio (una sola copia, quella di fromList).
  Future<Uint8List> bytes(Uint8List data) async =>
      await _submit([_kBytes, TransferableTypedData.fromList([data])]) as Uint8List;

  Future<Object> _submit(List<Object?> body) {
    final job = _Job(body);
    _queue.add(job);
    _pump();
    return job.completer.future;
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

  void _onReply(List<Object?> m) {
    final (job, w) = _pending.remove(m[0] as int)!;
    w.inflight--;
    final r = m[1];
    if (r is String) {
      job.completer.completeError(StateError(r));
    } else {
      job.completer.complete(r!);
    }
    _pump();
  }

  Future<void> close() async {
    await ready;
    for (final iso in _spawned) {
      iso.kill(priority: Isolate.immediate);
    }
    _rx.close();
    if (identical(this, _shared)) _shared = null;
  }
}

void _workerMain(SendPort out) {
  final rx = RawReceivePort();
  rx.handler = (Object? raw) {
    final m = raw as List<Object?>;
    final id = m[0] as int;
    Object result;
    try {
      switch (m[1] as int) {
        case _kFile:
          result = sha256FileSync(m[2] as String);
        case _kRanges:
          final r = m[3] as Int64List;
          final outBuf = Uint8List(16 * r.length);
          final f = File(m[2] as String).openSync();
          try {
            for (var i = 0; i < r.length; i += 2) {
              outBuf.setRange(16 * i, 16 * i + 32, _hashOpen(f, r[i], r[i + 1]));
            }
          } finally {
            f.closeSync();
          }
          result = outBuf;
        case _kBytes:
          result = sha256BytesSync((m[2] as TransferableTypedData).materialize().asUint8List());
        default:
          result = 'job sconosciuto';
      }
    } catch (e) {
      result = '$e';
    }
    out.send([id, result]);
  };
  out.send(rx.sendPort);
}
