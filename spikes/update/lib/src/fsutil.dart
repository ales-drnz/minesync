// Utilità di filesystem per scritture atomiche e durevoli.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

/// Scrive [bytes] in [path] in modo atomico: file temporaneo nella stessa
/// cartella, fsync, rename sopra l'originale, fsync della cartella.
/// Chi legge vede o il contenuto vecchio o quello nuovo, mai un file a metà.
Future<void> writeAtomic(String path, List<int> bytes) async {
  final tmp = '$path.tmp-$pid';
  final raf = await File(tmp).open(mode: FileMode.writeOnly);
  try {
    await raf.writeFrom(bytes);
    await raf.flush(); // fsync (FlushFileBuffers su Windows)
  } finally {
    await raf.close();
  }
  await renameRetry(tmp, path);
  fsyncDir(p.dirname(path));
}

/// Rename con qualche tentativo: su Windows antivirus/indicizzatore tengono
/// aperti per qualche centinaio di ms i file appena scritti (ERROR_ACCESS_DENIED
/// / SHARING_VIOLATION transitori). Su POSIX il primo tentativo basta.
Future<void> renameRetry(String from, String to, {bool dir = false}) async {
  for (var i = 0;; i++) {
    try {
      if (dir) {
        await Directory(from).rename(to);
      } else {
        await File(from).rename(to);
      }
      return;
    } on FileSystemException {
      if (!Platform.isWindows || i >= 20) rethrow;
      await Future<void>.delayed(Duration(milliseconds: 100 * (i + 1)));
    }
  }
}

/// Cancella ricorsivamente, senza errori se non esiste. Ritorna false se non
/// ci è riuscito (Windows: un exe della cartella è ancora in esecuzione).
Future<bool> rmrf(String path) async {
  try {
    final t = await FileSystemEntity.type(path, followLinks: false);
    if (t == FileSystemEntityType.notFound) return true;
    if (t == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else {
      await File(path).delete();
    }
    return true;
  } on FileSystemException {
    return false;
  }
}

typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32);
typedef _OpenD = int Function(Pointer<Utf8>, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdD = int Function(int);

/// fsync di una cartella (POSIX): rende durevole un rename appena fatto.
/// dart:io non lo espone, quindi FFI su libc. Su Windows non serve (NTFS
/// registra i metadati nel journal) ed è un no-op.
void fsyncDir(String dir) {
  if (Platform.isWindows) return;
  final libc = DynamicLibrary.process();
  final open = libc.lookupFunction<_OpenC, _OpenD>('open');
  final fsync = libc.lookupFunction<_FdC, _FdD>('fsync');
  final close = libc.lookupFunction<_FdC, _FdD>('close');
  final cpath = dir.toNativeUtf8();
  try {
    final fd = open(cpath, 0 /* O_RDONLY */);
    if (fd < 0) return;
    fsync(fd);
    close(fd);
  } finally {
    malloc.free(cpath);
  }
}

typedef _ChmodC = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodD = int Function(Pointer<Utf8>, int);
typedef _LinkC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>);
typedef _LinkD = int Function(Pointer<Utf8>, Pointer<Utf8>);

/// chmod(2) via FFI (dart:io non ha un'API per i permessi). No-op su Windows.
void chmodPosix(String path, int mode) {
  if (Platform.isWindows) return;
  final f = DynamicLibrary.process().lookupFunction<_ChmodC, _ChmodD>('chmod');
  final c = path.toNativeUtf8();
  try {
    if (f(c, mode) != 0) throw FileSystemException('chmod fallito', path);
  } finally {
    malloc.free(c);
  }
}

/// link(2): hardlink [to] -> stesso inode di [from]. false se non riesce.
bool hardLink(String from, String to) {
  if (Platform.isWindows) return false;
  final f = DynamicLibrary.process().lookupFunction<_LinkC, _LinkD>('link');
  final a = from.toNativeUtf8(), b = to.toNativeUtf8();
  try {
    return f(a, b) == 0;
  } finally {
    malloc.free(a);
    malloc.free(b);
  }
}
