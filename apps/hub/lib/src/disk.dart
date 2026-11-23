// Spazio su disco e permessi dei file.
//
// La lettura dello spazio libero passa da un [DiskProbe] iniettabile: i test
// di disk_full usano un valore finto, [systemDiskProbe] quello vero di ms_core.
import 'dart:ffi';
import 'dart:io';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';
import 'package:ms_core/ms_core.dart' show diskSpace;

/// Spazio di un volume, in byte.
typedef DiskUsage = ({int free, int total});

/// Legge lo spazio del volume che contiene [path]; null se non si sa.
typedef DiskProbe = DiskUsage? Function(String path);

const int _gib = 1 << 30;

/// Soglia minima predefinita: max(1 GiB, 2 % del volume).
int defaultMinFree(int total) => math.max(_gib, total ~/ 50);

typedef _ChmodC = Int32 Function(Pointer<Utf8>, Uint32);
typedef _ChmodD = int Function(Pointer<Utf8>, int);

final DynamicLibrary _libc = DynamicLibrary.process();
final _ChmodD? _chmod = Platform.isWindows ? null : _libc.lookupFunction<_ChmodC, _ChmodD>('chmod');

/// Spazio del volume che contiene [path]; null se il sistema non risponde.
DiskUsage? systemDiskProbe(String path) {
  try {
    final d = diskSpace(path);
    return (free: d.free, total: d.total);
  } on FileSystemException {
    return null;
  }
}

/// chmod(2) del file [path]; no-op su Windows.
void chmodSync(String path, int mode) {
  final fn = _chmod;
  if (fn == null) return;
  final p = path.toNativeUtf8();
  try {
    if (fn(p, mode) != 0) throw FileSystemException('chmod fallito', path);
  } finally {
    malloc.free(p);
  }
}

final _sizeRe = RegExp(r'^\s*([0-9]+(?:\.[0-9]+)?)\s*([a-zA-Z]*)\s*$');

/// Interpreta una dimensione come `5GiB`, `500MB`, `1024`, `1.5 GiB`.
/// Lancia [FormatException] se manca il numero o l'unità è sconosciuta.
int parseBytes(String v) {
  final m = _sizeRe.firstMatch(v);
  if (m == null) throw FormatException('dimensione non valida: "$v"');
  final n = double.parse(m[1]!);
  final mult = switch (m[2]!.toLowerCase()) {
    '' || 'b' => 1,
    'k' || 'kb' => 1000,
    'kib' => 1 << 10,
    'm' || 'mb' => 1000 * 1000,
    'mib' => 1 << 20,
    'g' || 'gb' => 1000 * 1000 * 1000,
    'gib' => 1 << 30,
    't' || 'tb' => 1000 * 1000 * 1000 * 1000,
    'tib' => 1 << 40,
    _ => throw FormatException('unità sconosciuta: "$v"'),
  };
  return (n * mult).round();
}
