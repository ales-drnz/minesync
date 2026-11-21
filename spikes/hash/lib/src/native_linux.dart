// Linux: libcrypto di OpenSSL del sistema (EVP API, presente da 1.1.0).
//
// Le chiamate di update sono "leaf" e ricevono direttamente l'indirizzo del
// Uint8List (Dart >= 3.5): nessuna copia verso memoria nativa.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'backend.dart';

typedef _CtxNewN = Pointer<Void> Function();
typedef _CtxFreeN = Void Function(Pointer<Void>);
typedef _CtxFreeD = void Function(Pointer<Void>);
typedef _MdN = Pointer<Void> Function();
typedef _InitN = Int32 Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _InitD = int Function(Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _UpdN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Size);
typedef _UpdD = int Function(Pointer<Void>, Pointer<Uint8>, int);
typedef _FinN = Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);
typedef _FinD = int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Uint32>);

/// Nomi provati in ordine (MINESYNC_LIBCRYPTO, se impostata, per primo).
/// OpenSSL 4 mantiene l'API EVP usata qui (provato con 4.1.0). Lo .so senza
/// versione è solo un symlink di sviluppo (pacchetto -dev): non lo si cerca.
List<String> get _candidates => [
      ?Platform.environment['MINESYNC_LIBCRYPTO'],
      'libcrypto.so.3',
      'libcrypto.so.4',
      'libcrypto.so.1.1',
    ];

class OpenSslBackend implements Sha256Backend {
  OpenSslBackend._(this.detail, DynamicLibrary lib)
      : _ctxNew = lib.lookupFunction<_CtxNewN, _CtxNewN>('EVP_MD_CTX_new'),
        _ctxFreePtr = lib.lookup<NativeFunction<_CtxFreeN>>('EVP_MD_CTX_free'),
        _md = lib.lookupFunction<_MdN, _MdN>('EVP_sha256')(),
        _init = lib.lookupFunction<_InitN, _InitD>('EVP_DigestInit_ex', isLeaf: true),
        _upd = lib.lookupFunction<_UpdN, _UpdD>('EVP_DigestUpdate', isLeaf: true),
        _fin = lib.lookupFunction<_FinN, _FinD>('EVP_DigestFinal_ex', isLeaf: true) {
    _ctxFree = _ctxFreePtr.asFunction<_CtxFreeD>();
    _finalizer = NativeFinalizer(_ctxFreePtr.cast());
  }

  static OpenSslBackend load() {
    final errors = <String>[];
    for (final name in _candidates) {
      try {
        return OpenSslBackend._('openssl ($name)', DynamicLibrary.open(name));
      } catch (e) {
        errors.add('$name: $e');
      }
    }
    throw StateError('libcrypto non trovata (${errors.join('; ')})');
  }

  @override
  final String detail;
  @override
  String get name => 'openssl';
  @override
  bool get isNative => true;

  final _CtxNewN _ctxNew;
  final Pointer<NativeFunction<_CtxFreeN>> _ctxFreePtr;
  late final _CtxFreeD _ctxFree;
  late final NativeFinalizer _finalizer;
  final Pointer<Void> _md;
  final _InitD _init;
  final _UpdD _upd;
  final _FinD _fin;

  @override
  Sha256Ctx newCtx() => _OpenSslCtx(this);
}

class _OpenSslCtx extends NativeCtx implements Finalizable {
  _OpenSslCtx(this._b) : _ctx = _b._ctxNew() {
    if (_ctx == nullptr) throw StateError('EVP_MD_CTX_new fallita');
    _b._finalizer.attach(this, _ctx, detach: this);
    _init();
  }
  final OpenSslBackend _b;
  final Pointer<Void> _ctx;
  bool _disposed = false;

  void _init() {
    if (_b._init(_ctx, _b._md, nullptr) != 1) throw StateError('EVP_DigestInit_ex fallita');
  }

  @override
  void updatePtr(Pointer<Uint8> p, int n) {
    if (_b._upd(_ctx, p, n) != 1) throw StateError('EVP_DigestUpdate fallita');
  }

  @override
  Uint8List finish() {
    final len = (scratch + 32).cast<Uint32>();
    if (_b._fin(_ctx, scratch, len) != 1) throw StateError('EVP_DigestFinal_ex fallita');
    final r = takeDigest();
    _init();
    return r;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b._finalizer.detach(this);
    _b._ctxFree(_ctx);
  }
}
