// Calcolo dello SHA-256 al volo durante l'upload.
//
// Lezioni dalla prima misura (README, "iterazione 1"):
//  - package:crypto (puro Dart, AOT) fa ~166 MiB/s su un core di questo host;
//    nell'event loop lo bloccherebbe ~6 ms per MiB -> l'hash va fuori.
//  - un isolate per upload + TransferableTypedData (una copia + una
//    materializzazione per blocco) fa crescere il RSS (heap che si gonfia
//    prima che il GC raccolga: 16 upload -> 780 MiB, container in OOM) e, con
//    16 isolate che macinano su --cpus=2, la quota CFS si esaurisce e
//    l'event loop resta fermo centinaia di ms (p99 465 ms).
// Quindi: un POOL fisso di worker (default: CPU effettive del cgroup - 1,
// minimo 1) e i blocchi passano per memoria NATIVA (malloc): l'I/O copia il
// blocco nello slot nativo, il worker lo legge con una vista
// (Pointer.asTypedList, zero copie, zero garbage), l'ack libera lo slot.
//
// Modalità (HUB_HASH):
//  - dart    : package:crypto (default, quello richiesto dallo spike)
//  - openssl : EVP SHA-256 di libcrypto.so.3 via FFI (anteprima dell'hash
//              nativo; la scelta definitiva spetta allo spike dedicato)
//  - none    : nessun hash, nessuna verifica (misura del solo percorso di I/O)
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

enum HashMode { dart, openssl, none }

HashMode hashModeFrom(String? s) => switch (s) {
      'openssl' => HashMode.openssl,
      'none' => HashMode.none,
      _ => HashMode.dart,
    };

/// CPU effettive: quota del cgroup v2 (docker --cpus) se presente, altrimenti
/// i processori visti dal sistema (dentro un container sono quelli dell'host).
int effectiveCpus() {
  try {
    final f = File('/sys/fs/cgroup/cpu.max').readAsStringSync().trim().split(' ');
    if (f[0] != 'max') {
      final n = (int.parse(f[0]) / int.parse(f[1])).floor();
      if (n >= 1) return n;
    }
  } catch (_) {}
  return Platform.numberOfProcessors;
}

/// Pool di worker condiviso da tutti gli upload.
class HashPool {
  HashPool._(this.mode);
  final HashMode mode;
  final _workers = <SendPort>[];
  final _load = <int>[];
  final _pending = <int, _Job>{};
  int _nextJob = 0;
  late final ReceivePort _rp;

  static Future<HashPool> start(HashMode mode, int workers) async {
    final p = HashPool._(mode);
    if (mode == HashMode.none) return p;
    p._rp = ReceivePort();
    final ready = StreamController<SendPort>();
    p._rp.listen((m) {
      if (m is SendPort) {
        ready.add(m);
      } else if (m is List) {
        final job = p._pending[m[0] as int];
        if (job == null) return;
        if (m.length == 2) {
          job._ack(m[1] as int); // slot digerito
        } else {
          job._finish(m[2] as String?, m[1] as String?);
        }
      }
    });
    final it = StreamIterator(ready.stream);
    for (var i = 0; i < workers; i++) {
      await Isolate.spawn(_worker, [p._rp.sendPort, mode.index]);
      await it.moveNext();
      p._workers.add(it.current);
      p._load.add(0);
    }
    return p;
  }

  int get workers => _workers.length;

  /// Nuovo calcolo, assegnato al worker meno carico.
  HashJob begin() {
    if (mode == HashMode.none) return _NoHash();
    var w = 0;
    for (var i = 1; i < _load.length; i++) {
      if (_load[i] < _load[w]) w = i;
    }
    _load[w]++;
    final j = _Job(this, _nextJob++, w);
    _pending[j.id] = j;
    _workers[w].send([j.id, 'begin']);
    return j;
  }

  void _release(_Job j) {
    if (_pending.remove(j.id) != null) _load[j.worker]--;
  }
}

/// Un calcolo in corso. [slots] blocchi nativi da [slotSize] byte.
///
/// 8 x 256 KiB = 2 MiB per upload. Nota: dart:io consegna il corpo a pezzi
/// fino a ~4 MiB + SO_RCVBUF (socket_patch.dart: read() senza lunghezza
/// accorpa letture finché non supera 4 MiB, poi copia con toBytes): pezzi
/// così grandi finiscono direttamente nell'old space e li libera solo il
/// mark-sweep. Il RSS lo limita il tetto dell'heap (--old_gen_heap_size, vedi
/// Dockerfile/README), non la dimensione di questi slot.
abstract class HashJob {
  static const slots = 8;
  static const slotSize = 256 * 1024;
  static const reserveSlots = 4; // backpressure: 1 MiB libero prima del pezzo dopo

  /// Slot nativo libero in cui l'I/O copia il prossimo blocco.
  Future<int> acquire();

  /// Slot successivo se già libero, senza attese (null se occupato).
  int? tryAcquire();

  /// Attende che i prossimi [k] slot (in ordine di riuso) siano liberi.
  Future<void> reserve(int k);
  Uint8List view(int slot, int len);

  /// Consegna lo slot al worker (che lo libererà con l'ack).
  void submit(int slot, int len);

  /// Rilascio dello slot da parte dell'I/O (scrittura su disco completata).
  void writeDone(int slot);
  Future<String> close();
  void abort();
}

class _NoHash implements HashJob {
  final Pointer<Uint8> _mem = malloc<Uint8>(HashJob.slots * HashJob.slotSize);
  final _busy = List<Completer<void>?>.filled(HashJob.slots, null);
  int _next = 0;
  @override
  Future<int> acquire() async {
    final s = _next;
    _next = (_next + 1) % HashJob.slots;
    await _busy[s]?.future;
    _busy[s] = Completer<void>();
    return s;
  }

  @override
  int? tryAcquire() {
    final c = _busy[_next];
    if (c != null && !c.isCompleted) return null;
    final s = _next;
    _next = (_next + 1) % HashJob.slots;
    _busy[s] = Completer<void>();
    return s;
  }

  @override
  Future<void> reserve(int k) async {
    for (var i = 0; i < k; i++) {
      await _busy[(_next + i) % HashJob.slots]?.future;
    }
  }

  @override
  Uint8List view(int slot, int len) =>
      (_mem + slot * HashJob.slotSize).asTypedList(len);
  @override
  void submit(int slot, int len) {}
  @override
  void writeDone(int slot) => _busy[slot]?.complete();
  @override
  Future<String> close() async {
    malloc.free(_mem);
    return '';
  }

  @override
  void abort() => malloc.free(_mem);
}

class _Job implements HashJob {
  _Job(this.pool, this.id, this.worker);
  final HashPool pool;
  final int id, worker;
  final Pointer<Uint8> _mem = malloc<Uint8>(HashJob.slots * HashJob.slotSize);
  // ogni slot è libero quando sia il worker (ack) sia la scrittura hanno finito
  final _hashBusy = List<Completer<void>?>.filled(HashJob.slots, null);
  final _ioBusy = List<Completer<void>?>.filled(HashJob.slots, null);
  int _next = 0;
  final _done = Completer<String>();
  bool _freed = false;

  @override
  Future<int> acquire() async {
    final s = _next;
    _next = (_next + 1) % HashJob.slots;
    await _hashBusy[s]?.future;
    await _ioBusy[s]?.future;
    _hashBusy[s] = Completer<void>();
    _ioBusy[s] = Completer<void>();
    return s;
  }

  @override
  int? tryAcquire() {
    final h = _hashBusy[_next], w = _ioBusy[_next];
    if ((h != null && !h.isCompleted) || (w != null && !w.isCompleted)) return null;
    final s = _next;
    _next = (_next + 1) % HashJob.slots;
    _hashBusy[s] = Completer<void>();
    _ioBusy[s] = Completer<void>();
    return s;
  }

  @override
  Future<void> reserve(int k) async {
    for (var i = 0; i < k; i++) {
      final s = (_next + i) % HashJob.slots;
      await _hashBusy[s]?.future;
      await _ioBusy[s]?.future;
    }
  }

  @override
  Uint8List view(int slot, int len) =>
      (_mem + slot * HashJob.slotSize).asTypedList(len);

  @override
  void submit(int slot, int len) => pool._workers[worker]
      .send([id, (_mem + slot * HashJob.slotSize).address, len, slot]);

  @override
  void writeDone(int slot) => _ioBusy[slot]?.complete();

  void _ack(int slot) => _hashBusy[slot]?.complete();

  void _finish(String? hex, String? err) {
    if (_done.isCompleted) return;
    if (err == null && hex != null) {
      _done.complete(hex);
    } else {
      _done.completeError(StateError(err ?? 'hasher: contesto assente'));
    }
  }

  @override
  Future<String> close() async {
    pool._workers[worker].send([id, 'end']);
    try {
      return await _done.future;
    } finally {
      _free();
    }
  }

  @override
  void abort() {
    // il worker potrebbe ancora leggere uno slot già inviato: si chiede la
    // chiusura e si libera la memoria solo quando il worker ha risposto
    pool._workers[worker].send([id, 'end']);
    _done.future.whenComplete(_free).ignore();
  }

  void _free() {
    if (_freed) return;
    _freed = true;
    malloc.free(_mem);
    pool._release(this);
  }
}

// --- worker ---
void _worker(List<Object> args) {
  final out = args[0] as SendPort;
  final mode = HashMode.values[args[1] as int];
  final rp = ReceivePort();
  out.send(rp.sendPort);
  final ctx = <int, _Digester>{};
  rp.listen((m) {
    final l = m as List;
    final id = l[0] as int;
    try {
      if (l[1] == 'begin') {
        ctx[id] = mode == HashMode.openssl ? _OpenSslDigester() : _DartDigester();
      } else if (l[1] == 'end') {
        final d = ctx.remove(id);
        out.send([id, null, d?.finish()]);
      } else {
        final p = Pointer<Uint8>.fromAddress(l[1] as int);
        ctx[id]!.add(p, l[2] as int);
        out.send([id, l[3]]);
      }
    } catch (e) {
      ctx.remove(id);
      out.send([id, e.toString(), null]);
    }
  });
}

abstract class _Digester {
  void add(Pointer<Uint8> p, int len);
  String finish();
}

class _DartDigester implements _Digester {
  final _sink = _DigestSink();
  late final ByteConversionSink _in = sha256.startChunkedConversion(_sink);
  @override
  void add(Pointer<Uint8> p, int len) => _in.add(p.asTypedList(len));
  @override
  String finish() {
    _in.close();
    return _sink.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}

// --- OpenSSL 3 (libcrypto.so.3) via FFI ---
typedef _NewC = Pointer<Void> Function();
typedef _InitC = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _InitD = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _UpdC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _UpdD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _FinC = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _FinD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);

final DynamicLibrary _crypto = DynamicLibrary.open('libcrypto.so.3');
final _UpdD _upd = _crypto.lookupFunction<_UpdC, _UpdD>('EVP_DigestUpdate');
final _FinD _fin = _crypto.lookupFunction<_FinC, _FinD>('EVP_DigestFinal_ex');
final _FreeD _ctxFree = _crypto.lookupFunction<_FreeC, _FreeD>('EVP_MD_CTX_free');
final _NewC _ctxNew = _crypto.lookupFunction<_NewC, _NewC>('EVP_MD_CTX_new');
final _InitD _init = _crypto.lookupFunction<_InitC, _InitD>('EVP_DigestInit_ex');
final Pointer<Void> _sha256 = _crypto.lookupFunction<_NewC, _NewC>('EVP_sha256')();

class _OpenSslDigester implements _Digester {
  _OpenSslDigester() {
    if (_init(_ctx, _sha256, nullptr) != 1) throw StateError('EVP_DigestInit_ex');
  }
  final Pointer<Void> _ctx = _ctxNew();

  @override
  void add(Pointer<Uint8> p, int len) {
    if (_upd(_ctx, p, len) != 1) throw StateError('EVP_DigestUpdate');
  }

  @override
  String finish() {
    final md = malloc<Uint8>(32);
    final n = malloc<Uint32>();
    try {
      if (_fin(_ctx, md, n) != 1) throw StateError('EVP_DigestFinal_ex');
      return [for (final b in md.asTypedList(32)) b.toRadixString(16).padLeft(2, '0')].join();
    } finally {
      malloc.free(md);
      malloc.free(n);
      _ctxFree(_ctx);
    }
  }
}
