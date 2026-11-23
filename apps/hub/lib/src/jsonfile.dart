// Lettura e scrittura dei documenti JSON dell'hub. Ogni scrittura passa da
// writeAtomic di ms_core (temporaneo, fsync, rename, fsync della cartella).
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_core/ms_core.dart';

import 'disk.dart';

/// Legge e decodifica [path]. Lancia [FileSystemException] se manca e
/// [FormatException] se il contenuto non è JSON valido.
Future<Object?> readJsonFile(String path) async {
  final bytes = await File(path).readAsBytes();
  return jsonDecode(utf8.decode(bytes));
}

/// Come [readJsonFile] ma null se il file non esiste o è illeggibile.
Future<Object?> tryReadJsonFile(String path) async {
  try {
    return await readJsonFile(path);
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Scrive [value] come JSON in [path], in modo atomico e durevole. Con
/// [mode] (es. 0x180 = 0600) il temporaneo prende quei permessi prima del
/// rename, così il file non è mai leggibile da altri.
Future<void> writeJsonAtomic(String path, Object? value, {int? mode}) async {
  final bytes = utf8.encode(jsonEncode(value));
  if (mode == null) return writeAtomic(path, bytes);
  final tmp = await writeTemp(path, Uint8List.fromList(bytes));
  try {
    chmodSync(tmp, mode);
  } catch (_) {
    await File(tmp).delete();
    rethrow;
  }
  await commitTemp(tmp, path);
}

/// Cancella i temporanei di writeAtomic rimasti in [dir] da un crash.
Future<int> sweepPartFiles(String dir) async {
  var n = 0;
  final d = Directory(dir);
  if (!await d.exists()) return 0;
  await for (final e in d.list()) {
    if (e is File && e.path.endsWith(partSuffix)) {
      try {
        await e.delete();
        n++;
      } on FileSystemException {
        // già sparito
      }
    }
  }
  return n;
}
