// Windows: CNG (bcrypt.dll, sempre presente da Vista; flag REUSABLE da 8).
//
// NON verificato localmente (nessun Windows): lo prova il job CI
// windows-latest.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'backend.dart';

typedef _OpenN = Int32 Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, Uint32);
typedef _OpenD = int Function(Pointer<Pointer<Void>>, Pointer<Utf16>, Pointer<Utf16>, int);
typedef _CreateN = Int32 Function(
    Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Uint8>, Uint32, Pointer<Uint8>, Uint32, Uint32);
typedef _CreateD = int Function(
    Pointer<Void>, Pointer<Pointer<Void>>, Pointer<Uint8>, int, Pointer<Uint8>, int, int);
typedef _DataN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Uint32, Uint32);
typedef _DataD = int Function(Pointer<Void>, Pointer<Uint8>, int, int);
typedef _DestroyN = Int32 Function(Pointer<Void>);
typedef _DestroyD = int Function(Pointer<Void>);

const _reusable = 0x00000020; // BCRYPT_HASH_REUSABLE_FLAG
const _maxUpdate = 1 << 30; // ULONG

String _st(int s) => '0x${(s & 0xffffffff).toRadixString(16)}';

class CngBackend implements Sha256Backend {
  CngBackend._(DynamicLibrary lib)
      : _create = lib.lookupFunction<_CreateN, _CreateD>('BCryptCreateHash'),
        _data = lib.lookupFunction<_DataN, _DataD>('BCryptHashData', isLeaf: true),
        _finish = lib.lookupFunction<_DataN, _DataD>('BCryptFinishHash', isLeaf: true),
        _destroy = lib.lookupFunction<_DestroyN, _DestroyD>('BCryptDestroyHash') {
    final open = lib.lookupFunction<_OpenN, _OpenD>('BCryptOpenAlgorithmProvider');
    final ph = calloc<Pointer<Void>>();
    final id = 'SHA256'.toNativeUtf16();
    try {
      final st = open(ph, id, nullptr, 0);
      if (st != 0) throw StateError('BCryptOpenAlgorithmProvider: ${_st(st)}');
      // Il provider resta aperto per tutta la vita dell'isolate.
      _alg = ph.value;
    } finally {
      calloc.free(ph);
      calloc.free(id);
    }
    _gc = Finalizer<Pointer<Void>>((h) => _destroy(h));
  }

  static CngBackend load() => CngBackend._(DynamicLibrary.open('bcrypt.dll'));

  @override
  String get detail => 'cng (bcrypt.dll)';
  @override
  String get name => 'cng';
  @override
  bool get isNative => true;

  late final Pointer<Void> _alg;
  final _CreateD _create;
  final _DataD _data;
  final _DataD _finish;
  final _DestroyD _destroy;
  late final Finalizer<Pointer<Void>> _gc;

  @override
  Sha256Ctx newCtx() {
    final ph = calloc<Pointer<Void>>();
    try {
      final st = _create(_alg, ph, nullptr, 0, nullptr, 0, _reusable);
      if (st != 0) throw StateError('BCryptCreateHash: ${_st(st)}');
      return _CngCtx(this, ph.value);
    } finally {
      calloc.free(ph);
    }
  }
}

class _CngCtx extends NativeCtx {
  _CngCtx(this._b, this._h) {
    _b._gc.attach(this, _h, detach: this);
  }
  final CngBackend _b;
  final Pointer<Void> _h;
  bool _disposed = false;

  @override
  void updatePtr(Pointer<Uint8> p, int n) {
    for (var s = 0; s < n; s += _maxUpdate) {
      final st = _b._data(_h, p + s, (n - s) < _maxUpdate ? n - s : _maxUpdate, 0);
      if (st != 0) throw StateError('BCryptHashData: ${_st(st)}');
    }
  }

  @override
  Uint8List finish() {
    // Con REUSABLE il contesto riparte da zero dopo FinishHash.
    final st = _b._finish(_h, scratch, 32, 0);
    if (st != 0) throw StateError('BCryptFinishHash: ${_st(st)}');
    return takeDigest();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b._gc.detach(this);
    _b._destroy(_h);
  }
}
