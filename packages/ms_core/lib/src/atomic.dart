// Scritture atomiche e durevoli: file temporaneo nella stessa cartella,
// fsync, rename sul nome finale, fsync della cartella. Dopo un'interruzione
// di corrente resta il file vecchio o quello nuovo, mai uno a metà.
//
// dart:io non sa fare fsync di una cartella (File.open rifiuta le cartelle e
// Directory non ha sync): su Linux e macOS si usa open+fsync della libc via
// FFI. Su Windows le cartelle non si sincronizzano e MoveFileEx basta.
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

typedef _OpenC = Int32 Function(Pointer<Utf8>, Int32, VarArgs<(Int32,)>);
typedef _OpenD = int Function(Pointer<Utf8>, int, int);
typedef _FdC = Int32 Function(Int32);
typedef _FdD = int Function(int);

final DynamicLibrary _libc = DynamicLibrary.process();
final _OpenD _open = _libc.lookupFunction<_OpenC, _OpenD>('open');
final _FdD _fsync = _libc.lookupFunction<_FdC, _FdD>('fsync');
final _FdD _close = _libc.lookupFunction<_FdC, _FdD>('close');

/// Suffisso dei file temporanei: escluso dalla sincronizzazione.
const String partSuffix = '.minesyncpart';

final _rng = Random.secure();

/// Nome temporaneo accanto a [path].
String tempPathFor(String path) => '$path.${_rng.nextInt(1 << 32).toRadixString(36)}$partSuffix';

/// fsync sincrono di una cartella. No-op su Windows.
void fsyncDirSync(String dir) {
  if (Platform.isWindows) return;
  final p = dir.toNativeUtf8();
  try {
    // O_RDONLY = 0 ovunque; O_DIRECTORY cambia valore tra architetture.
    final fd = _open(p, 0, 0);
    if (fd < 0) throw FileSystemException('apertura della cartella fallita', dir);
    final r = _fsync(fd);
    _close(fd);
    if (r != 0) throw FileSystemException('fsync della cartella fallito', dir);
  } finally {
    malloc.free(p);
  }
}

/// fsync di una cartella fuori dall'event loop (la chiamata FFI blocca).
Future<void> fsyncDir(String dir) async {
  if (Platform.isWindows) return;
  await Isolate.run(() => fsyncDirSync(dir));
}

/// Scrive [bytes] in [path] in modo atomico e durevole.
Future<void> writeAtomic(String path, List<int> bytes) async {
  final tmp = tempPathFor(path);
  final raf = await File(tmp).open(mode: FileMode.writeOnly);
  try {
    await raf.writeFrom(bytes);
    await raf.flush(); // fsync(2) sul thread pool di I/O del VM
  } catch (_) {
    await raf.close();
    await _deleteQuietly(tmp);
    rethrow;
  }
  await raf.close();
  await commitTemp(tmp, path);
}

/// Versione sincrona di [writeAtomic].
void writeAtomicSync(String path, List<int> bytes) {
  final tmp = tempPathFor(path);
  final raf = File(tmp).openSync(mode: FileMode.writeOnly);
  try {
    raf
      ..writeFromSync(bytes)
      ..flushSync();
  } catch (_) {
    raf.closeSync();
    _deleteQuietlySync(tmp);
    rethrow;
  }
  raf.closeSync();
  try {
    File(tmp).renameSync(path);
  } catch (_) {
    _deleteQuietlySync(tmp);
    rethrow;
  }
  fsyncDirSync(File(path).parent.path);
}

/// Porta un file temporaneo già sincronizzato al nome finale e rende
/// durevole la rinomina.
Future<void> commitTemp(String tmp, String path) async {
  try {
    await File(tmp).rename(path);
  } catch (_) {
    await _deleteQuietly(tmp);
    rethrow;
  }
  await fsyncDir(File(path).parent.path);
}

/// Scrive [bytes] in un file temporaneo sincronizzato e ne restituisce il
/// percorso (per chi deve verificare il contenuto prima di [commitTemp]).
Future<String> writeTemp(String path, Uint8List bytes) async {
  final tmp = tempPathFor(path);
  final raf = await File(tmp).open(mode: FileMode.writeOnly);
  try {
    await raf.writeFrom(bytes);
    await raf.flush();
  } finally {
    await raf.close();
  }
  return tmp;
}

Future<void> _deleteQuietly(String p) async {
  try {
    await File(p).delete();
  } on FileSystemException {
    // già sparito
  }
}

void _deleteQuietlySync(String p) {
  try {
    File(p).deleteSync();
  } on FileSystemException {
    // già sparito
  }
}
