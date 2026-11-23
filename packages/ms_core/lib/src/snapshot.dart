// Istantanea di una copia locale in attesa di caricamento (outbox) e attesa
// che una cartella smetta di cambiare prima di fotografarla.
import 'dart:async';
import 'dart:io';

import 'package:ms_protocol/ms_protocol.dart';

/// Istantanea congelata: manifest e base da cui parte. I blob nuovi sono in
/// `.minesync/outbox/<hash>`.
final class Snapshot {
  const Snapshot(this.baseN, this.baseDigest, this.manifest, this.at, this.kept);

  final int baseN;
  final String baseDigest;
  final Manifest manifest;

  /// Momento dell'istantanea (è l'ora del salvataggio, non del caricamento).
  final DateTime at;

  /// File saltati per cui resta la versione della base.
  final List<String> kept;

  Map<String, Object?> toJson(String space) => {
    'v': 1,
    'space': space,
    'baseN': baseN,
    'baseDigest': baseDigest,
    'at': at.toIso8601String(),
    'kept': kept,
    'manifest': manifest.toJson(),
  };

  static Snapshot? fromJson(Map<String, Object?> j, String space) {
    if (j['space'] != space) return null;
    return Snapshot(
      j['baseN']! as int,
      j['baseDigest']! as String,
      Manifest.fromJson(j['manifest']),
      DateTime.parse(j['at']! as String),
      [for (final k in j['kept']! as List<Object?>) k! as String],
    );
  }
}

/// Impronta di una cartella: dimensione e data di ogni file (esclusi i
/// percorsi riservati). Due impronte uguali = nessuna scrittura nel mezzo.
Future<String> treeFingerprint(String root, Exclusions ex) async {
  final b = StringBuffer();
  Future<void> walk(Directory d, String rel) async {
    final entries = await d.list(followLinks: false).toList()
      ..sort((a, c) => a.path.compareTo(c.path));
    for (final e in entries) {
      final name = e.path.substring(e.path.lastIndexOf(Platform.pathSeparator) + 1);
      final r = rel.isEmpty ? name : '$rel/$name';
      if (e is Directory) {
        if (!ex.excludesDir(r)) await walk(e, r);
      } else if (e is File && !ex.excludes(r)) {
        try {
          final st = e.statSync();
          b.write('$r ${st.size} ${st.modified.microsecondsSinceEpoch}\n');
        } on FileSystemException {
          // sparito nel frattempo: lo dirà l'impronta successiva
        }
      }
    }
  }

  await walk(Directory(root), '');
  return b.toString();
}

/// Aspetta che [root] resti ferma per [stable]. Una scrittura tardiva
/// allunga l'attesa; dopo [cap] restituisce false.
Future<bool> waitQuiet(
  String root,
  Exclusions ex, {
  Duration stable = const Duration(seconds: 2),
  Duration cap = const Duration(seconds: 30),
  Duration poll = const Duration(milliseconds: 200),
}) async {
  final sw = Stopwatch()..start();
  var last = await treeFingerprint(root, ex);
  var since = sw.elapsed;
  while (sw.elapsed < cap) {
    await Future<void>.delayed(poll);
    final now = await treeFingerprint(root, ex);
    if (now != last) {
      last = now;
      since = sw.elapsed;
    } else if (sw.elapsed - since >= stable) {
      return true;
    }
  }
  return false;
}
