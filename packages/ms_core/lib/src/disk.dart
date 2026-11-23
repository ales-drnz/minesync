// Spazio libero su disco: dart:io non lo espone, quindi FFI verso la libc
// (statvfs su Linux, statfs su macOS) o kernel32 (GetDiskFreeSpaceExW).
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Spazio di un volume, in byte.
final class DiskSpace {
  const DiskSpace(this.free, this.total);

  /// Byte disponibili per l'utente corrente.
  final int free;
  final int total;

  @override
  String toString() => 'DiskSpace(free: $free, total: $total)';
}

/// Spazio del volume che contiene [path] (che deve esistere).
DiskSpace diskSpace(String path) {
  if (Platform.isWindows) return _windows(path);
  if (Platform.isMacOS) return _macos(path);
  return _linux(path);
}

// Linux a 64 bit: struct statvfs inizia con f_bsize, f_frsize, f_blocks,
// f_bfree, f_bavail, tutti a 64 bit (x86_64 e arm64).
typedef _StatvfsC = Int32 Function(Pointer<Utf8>, Pointer<Uint64>);
typedef _StatvfsD = int Function(Pointer<Utf8>, Pointer<Uint64>);

DiskSpace _linux(String path) {
  final f = DynamicLibrary.process().lookupFunction<_StatvfsC, _StatvfsD>('statvfs');
  final p = path.toNativeUtf8();
  final buf = calloc<Uint64>(64); // la struct è di 112 byte: margine abbondante
  try {
    if (f(p, buf) != 0) throw FileSystemException('statvfs fallita', path);
    final frsize = buf[1] == 0 ? buf[0] : buf[1];
    return DiskSpace(buf[4] * frsize, buf[2] * frsize);
  } finally {
    calloc
      ..free(p)
      ..free(buf);
  }
}

// macOS: struct statfs a 64 bit (simbolo "statfs" su arm64, "statfs$INODE64"
// su x86_64): uint32 f_bsize, int32 f_iosize, uint64 f_blocks, f_bfree,
// f_bavail. statvfs non va bene: lì i contatori sono a 32 bit.
typedef _StatfsC = Int32 Function(Pointer<Utf8>, Pointer<Uint8>);
typedef _StatfsD = int Function(Pointer<Utf8>, Pointer<Uint8>);

DiskSpace _macos(String path) {
  final lib = DynamicLibrary.process();
  final name = Abi.current() == Abi.macosX64 ? r'statfs$INODE64' : 'statfs';
  final f = lib.lookupFunction<_StatfsC, _StatfsD>(name);
  final p = path.toNativeUtf8();
  final buf = calloc<Uint8>(4096); // struct statfs: 2168 byte
  try {
    if (f(p, buf) != 0) throw FileSystemException('statfs fallita', path);
    final bsize = buf.cast<Uint32>()[0];
    final u64 = (buf + 8).cast<Uint64>();
    return DiskSpace(u64[2] * bsize, u64[0] * bsize);
  } finally {
    calloc
      ..free(p)
      ..free(buf);
  }
}

typedef _FreeC = Int32 Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);
typedef _FreeD = int Function(Pointer<Utf16>, Pointer<Uint64>, Pointer<Uint64>, Pointer<Uint64>);

DiskSpace _windows(String path) {
  final f = DynamicLibrary.open(
    'kernel32.dll',
  ).lookupFunction<_FreeC, _FreeD>('GetDiskFreeSpaceExW');
  final p = path.toNativeUtf16();
  final out = calloc<Uint64>(3);
  try {
    if (f(p, out, out + 1, out + 2) == 0) {
      throw FileSystemException('GetDiskFreeSpaceExW fallita', path);
    }
    return DiskSpace(out[0], out[1]);
  } finally {
    calloc
      ..free(p)
      ..free(out);
  }
}
