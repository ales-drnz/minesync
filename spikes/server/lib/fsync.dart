// fsync della directory da Dart.
//
// dart:io non offre un modo per fare fsync di una directory:
//  - File(dir).open() su Linux fallisce (il VM rifiuta le directory con EISDIR,
//    verificato da tool/probe.dart);
//  - Directory non ha né open() né sync.
// RandomAccessFile.flush() invece È fsync(2) sul file (file_linux.cc del VM:
// File::Flush -> fsync(fd)), e gira sul thread pool di I/O del VM, quindi non
// blocca l'event loop. Per la directory serve la FFI: open(O_RDONLY) + fsync +
// close dalla libc del processo (il binario AOT è comunque linkato a glibc).
//
// O_RDONLY = 0 su tutte le architetture Linux; NON usiamo O_DIRECTORY perché
// il suo valore cambia tra x86_64 (0x10000) e arm64 (0x4000).
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>);
typedef _OpenD = int Function(Pointer<Utf8>, int, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdD = int Function(int);

final DynamicLibrary _libc = DynamicLibrary.process();
final _OpenD _open = _libc.lookupFunction<_OpenC, _OpenD>('open');
final _FdD _fsync = _libc.lookupFunction<_FdC, _FdD>('fsync');
final _FdD _close = _libc.lookupFunction<_FdC, _FdD>('close');

/// fsync sincrono della directory (blocca il thread chiamante).
/// Ritorna 0 se ok, altrimenti -1 (errno non è esposto: per lo spike basta).
int fsyncDirSync(String dir) {
  if (Platform.isWindows) return 0; // su Windows le directory non si sincronizzano
  final p = dir.toNativeUtf8();
  try {
    final fd = _open(p, 0, 0);
    if (fd < 0) return -1;
    final r = _fsync(fd);
    _close(fd);
    return r;
  } finally {
    malloc.free(p);
  }
}

/// fsync della directory fuori dall'event loop: la chiamata FFI è bloccante e
/// sotto carico (16 scrittori) può durare decine di ms, quindi gira in un
/// isolate di supporto (Isolate.run: stesso gruppo, avvio ~sub-ms).
Future<void> fsyncDir(String dir) async {
  final r = await Isolate.run(() => fsyncDirSync(dir));
  if (r != 0) throw FileSystemException('fsync della directory fallito', dir);
}
