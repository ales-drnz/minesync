// Interfaccia comune dei backend SHA-256 e selezione del backend.
//
// Ordine: backend nativo della piattaforma (CNG / CommonCrypto / OpenSSL),
// poi fallback puro Dart. La variabile d'ambiente MINESYNC_HASH_BACKEND
// forza un backend (native | hashlib | crypto): serve per i benchmark e
// per provare il fallback senza disinstallare librerie.
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'native_linux.dart' as linux;
import 'native_macos.dart' as macos;
import 'native_windows.dart' as windows;
import 'pure.dart';

/// Contesto incrementale SHA-256. Riutilizzabile: dopo [finish] riparte da
/// capo, così i worker non riallocano un contesto per ogni file.
abstract class Sha256Ctx {
  /// Aggiunge [data] (eventualmente solo [start]..[end]).
  void update(Uint8List data, [int start = 0, int? end]);

  /// Area di staging da 1 MiB: chi legge da file ci legge dentro e poi
  /// chiama [updateBuffer], così i byte vanno dal kernel al hash senza
  /// altre copie (per i backend nativi è memoria nativa).
  Uint8List get buffer;

  /// Aggiunge i primi [n] byte di [buffer].
  void updateBuffer(int n);

  /// Chiude il digest corrente (32 byte) e reinizializza il contesto.
  Uint8List finish();

  /// Libera le risorse native. Dopo dispose il contesto non è usabile.
  void dispose();
}

abstract class Sha256Backend {
  /// Nome breve, es. "openssl", "commoncrypto", "cng", "hashlib", "crypto".
  String get name;

  /// Dettaglio per il log (libreria caricata, motivo del fallback, ...).
  String get detail;

  bool get isNative;

  Sha256Ctx newCtx();
}

/// Backend scelto per questo isolate (ogni isolate ricarica la libreria:
/// DynamicLibrary.open è economico e il risultato è identico).
final Sha256Backend backend = _select(Platform.environment['MINESYNC_HASH_BACKEND']);

/// Backend per nome, per i confronti nei test. null se non disponibile.
Sha256Backend? backendByName(String name) {
  switch (name) {
    case 'native':
      return _tryNative().$1;
    case 'hashlib':
      return HashlibBackend('');
    case 'crypto':
      return CryptoBackend('');
  }
  return null;
}

(Sha256Backend?, String) _tryNative() {
  try {
    if (Platform.isLinux || Platform.isAndroid) return (linux.OpenSslBackend.load(), '');
    if (Platform.isMacOS || Platform.isIOS) return (macos.CommonCryptoBackend.load(), '');
    if (Platform.isWindows) return (windows.CngBackend.load(), '');
    return (null, 'piattaforma non supportata');
  } catch (e) {
    return (null, '$e');
  }
}

Sha256Backend _select(String? forced) {
  if (forced == 'hashlib') return HashlibBackend('forzato da MINESYNC_HASH_BACKEND');
  if (forced == 'crypto') return CryptoBackend('forzato da MINESYNC_HASH_BACKEND');
  final (native, why) = _tryNative();
  if (native != null) return native;
  // Fallback: package:crypto. hashlib in AOT è più lento (112 vs 180 MB/s,
  // misurato, vedi README).
  return CryptoBackend('nativo non disponibile: $why');
}

/// Dimensione dell'area di staging.
const stageSize = 1 << 20;

/// Base dei backend FFI. `.address` dei Uint8List funziona solo con le
/// funzioni @Native statiche, non con quelle cercate in una libreria
/// caricata a runtime: per questo i dati passano da un buffer nativo.
abstract class NativeCtx implements Sha256Ctx {
  NativeCtx() : this._(malloc<Uint8>(stageSize + 64));
  // Il blocco nativo si libera da solo quando la sua vista esterna viene
  // raccolta dal GC. [buffer] è una sublistView di quella vista e la tiene
  // viva (un campo "proprietario" non letto verrebbe eliminato dall'AOT:
  // provato, segfault).
  NativeCtx._(this._stage)
      : buffer = Uint8List.sublistView(
            _stage.asTypedList(stageSize + 64, finalizer: malloc.nativeFree), 0, stageSize);
  final Pointer<Uint8> _stage;
  @override
  final Uint8List buffer;

  /// 64 byte nativi dopo l'area di staging, per digest e lunghezze in uscita.
  Pointer<Uint8> get scratch => _stage + stageSize;

  /// Copia del digest dallo scratch.
  Uint8List takeDigest() => Uint8List.fromList(scratch.asTypedList(32));

  /// Aggiunge [n] byte da memoria nativa.
  void updatePtr(Pointer<Uint8> p, int n);

  @override
  void updateBuffer(int n) {
    if (n > 0) updatePtr(_stage, n);
  }

  /// Dati nell'heap Dart: copia a blocchi nell'area nativa (memcpy, ~10x
  /// più veloce dell'hash stesso).
  @override
  void update(Uint8List data, [int start = 0, int? end]) {
    final e = end ?? data.length;
    final b = buffer;
    for (var s = start; s < e; s += stageSize) {
      final n = (e - s) < stageSize ? e - s : stageSize;
      b.setRange(0, n, data, s);
      updatePtr(_stage, n);
    }
  }
}
