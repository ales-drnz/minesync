// macOS: CommonCrypto in libSystem (sempre presente, nessuna dipendenza).
//
// Verificato dalla CI su macos-latest.
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'backend.dart';

typedef _InitN = Int32 Function(Pointer<Uint8>);
typedef _InitD = int Function(Pointer<Uint8>);
typedef _UpdN = Int32 Function(Pointer<Uint8>, Pointer<Uint8>, Uint32);
typedef _UpdD = int Function(Pointer<Uint8>, Pointer<Uint8>, int);
typedef _FinN = Int32 Function(Pointer<Uint8>, Pointer<Uint8>);
typedef _FinD = int Function(Pointer<Uint8>, Pointer<Uint8>);

/// sizeof(CC_SHA256_CTX) = 104 byte; teniamo margine.
const _ctxSize = 128;

/// CC_LONG è uint32: gli update più grandi vanno spezzati.
const _maxUpdate = 1 << 30;

final _finalizer = NativeFinalizer(malloc.nativeFree);

class CommonCryptoBackend implements Sha256Backend {
  CommonCryptoBackend._(DynamicLibrary lib)
    : _init = lib.lookupFunction<_InitN, _InitD>('CC_SHA256_Init', isLeaf: true),
      _upd = lib.lookupFunction<_UpdN, _UpdD>('CC_SHA256_Update', isLeaf: true),
      _fin = lib.lookupFunction<_FinN, _FinD>('CC_SHA256_Final', isLeaf: true);

  static CommonCryptoBackend load() =>
      CommonCryptoBackend._(DynamicLibrary.open('/usr/lib/libSystem.B.dylib'));

  @override
  String get detail => 'commoncrypto (libSystem.B.dylib)';
  @override
  String get name => 'commoncrypto';
  @override
  bool get isNative => true;

  final _InitD _init;
  final _UpdD _upd;
  final _FinD _fin;

  @override
  Sha256Ctx newCtx() => _CcCtx(this);
}

class _CcCtx extends NativeCtx implements Finalizable {
  _CcCtx(this._b) : _ctx = malloc<Uint8>(_ctxSize) {
    _finalizer.attach(this, _ctx.cast(), detach: this);
    _b._init(_ctx);
  }
  final CommonCryptoBackend _b;
  final Pointer<Uint8> _ctx;
  bool _disposed = false;

  @override
  void updatePtr(Pointer<Uint8> p, int n) {
    for (var s = 0; s < n; s += _maxUpdate) {
      _b._upd(_ctx, p + s, (n - s) < _maxUpdate ? n - s : _maxUpdate);
    }
  }

  @override
  Uint8List finish() {
    _b._fin(scratch, _ctx);
    _b._init(_ctx);
    return takeDigest();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _finalizer.detach(this);
    malloc.free(_ctx);
  }
}
