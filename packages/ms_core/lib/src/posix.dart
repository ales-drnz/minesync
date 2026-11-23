// Permessi dei file su Linux e macOS: dart:io legge il modo (FileStat.mode)
// ma non sa cambiarlo, quindi chmod della libc via FFI.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _ChmodLinuxC = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodMacC = Int32 Function(Pointer<Utf8>, Uint16);
typedef _ChmodD = int Function(Pointer<Utf8>, int);

final _ChmodD? _chmod = Platform.isWindows
    ? null
    : Platform.isMacOS
    ? DynamicLibrary.process().lookupFunction<_ChmodMacC, _ChmodD>('chmod')
    : DynamicLibrary.process().lookupFunction<_ChmodLinuxC, _ChmodD>('chmod');

/// Imposta il bit di esecuzione di [path] dove c'è quello di lettura (come
/// `chmod +x` rispettoso del resto), o lo toglie. Su Windows non fa niente.
/// Restituisce false se il file system rifiuta (es. EPERM su una chiavetta).
bool setExecutable(String path, bool x) {
  final f = _chmod;
  if (f == null) return true;
  final mode = FileStat.statSync(path).mode & 0x1ff; // 0o777
  final read = mode & 0x124; // 0o444
  final next = x ? mode | (read >> 2) : mode & ~0x49; // 0o111
  if (next == mode) return true;
  final p = path.toNativeUtf8();
  try {
    return f(p, next) == 0;
  } finally {
    malloc.free(p);
  }
}
