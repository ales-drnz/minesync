// Scansione di una cartella locale: produce il manifest di quello che c'è su
// disco, riusando gli hash già calcolati quando dimensione e data di modifica
// dimostrano che il file non è cambiato.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:ms_protocol/ms_protocol.dart';
import 'package:unorm_dart/unorm_dart.dart' as unorm;

import 'atomic.dart';
import 'hasher.dart';

/// Un file modificato da meno di così può cambiare ancora nello stesso tick
/// di mtime: la sua voce di cache non viene riusata alla scansione dopo.
const Duration racyWindow = Duration(seconds: 2);

/// Letture di un file che cambia mentre lo si legge, prima di lasciarlo fuori.
const int stableTries = 4;

/// Voce della cache degli hash.
final class CacheEntry {
  const CacheEntry({
    required this.size,
    required this.mtime,
    required this.h,
    required this.chunks,
    required this.x,
    this.racy = false,
  });

  factory CacheEntry.fromJson(Object? j) {
    final l = j as List<Object?>;
    final c = l[3] as List<Object?>?;
    return CacheEntry(
      size: l[0] as int,
      mtime: l[1] as int,
      h: l[2] as String,
      chunks: c == null ? null : [for (final k in c) Chunk.fromJson(k)],
      x: l[4] == true,
      racy: l.length > 5 && l[5] == true,
    );
  }

  final int size;

  /// Data di modifica in microsecondi dall'epoch.
  final int mtime;
  final String h;
  final List<Chunk>? chunks;
  final bool x;

  /// Modificato a ridosso della scansione: da ricontrollare la prossima volta.
  final bool racy;

  FileEntry get entry => FileEntry(size: size, h: h, chunks: chunks, x: x);

  List<Object?> toJson() => [
    size,
    mtime,
    h,
    chunks == null ? null : [for (final c in chunks!) c.toJson()],
    x,
    if (racy) true,
  ];
}

/// Cache degli hash di una cartella, per percorso relativo.
final class HashCache {
  HashCache([Map<String, CacheEntry>? entries]) : entries = entries ?? {};

  /// Legge la cache; un file assente o illeggibile dà una cache vuota (costa
  /// solo un nuovo hash di tutto, mai un dato sbagliato).
  static HashCache load(String path) {
    try {
      final j = jsonDecode(File(path).readAsStringSync());
      final m = (j as Map<String, Object?>)['files'] as Map<String, Object?>;
      return HashCache({for (final e in m.entries) e.key: CacheEntry.fromJson(e.value)});
    } on Object {
      return HashCache();
    }
  }

  final Map<String, CacheEntry> entries;

  Future<void> save(String path) => writeAtomic(
    path,
    utf8.encode(
      jsonEncode({
        'v': 1,
        'files': {for (final e in entries.entries) e.key: e.value.toJson()},
      }),
    ),
  );
}

/// La scansione non può proseguire (non un problema di un singolo file).
final class ScanException implements Exception {
  const ScanException(this.kind, this.path);

  /// `dirSymlink`: una cartella è un collegamento simbolico; il suo contenuto
  /// sparirebbe dal manifest e il push lo cancellerebbe per tutti.
  final String kind;
  final String path;

  @override
  String toString() => 'ScanException($kind): $path';
}

/// Risultato di una scansione.
final class ScanResult {
  ScanResult(this.manifest, this.cache, this.unreadable, this.badNames, this.caseDups);

  final Manifest manifest;
  final HashCache cache;

  /// File (o cartelle, con "/" finale) che non si sono potuti leggere:
  /// bloccati, senza permessi, o che hanno continuato a cambiare.
  final List<String> unreadable;

  /// Nomi non portabili (validi su questo sistema ma non su tutti): saltati.
  final List<String> badNames;

  /// Percorsi tolti perché uguali a un altro a meno di maiuscole.
  final List<String> caseDups;

  /// Percorsi saltati per qualunque motivo: chi fa il push deve tenerne la
  /// versione dell'hub invece di cancellarli.
  Iterable<String> get skipped => [...unreadable, ...badNames, ...caseDups];
}

/// Vero se il file è un region file di Minecraft.
bool isRegionFile(String rel) {
  final l = rel.toLowerCase();
  return l.endsWith('.mca') || l.endsWith('.mcr');
}

/// Vero se dimensione e data non bastano a dire che il file è invariato.
/// Su Windows è così per i region file: finché il server li tiene aperti la
/// data di modifica non si aggiorna, e un confronto per data salterebbe in
/// silenzio proprio le region appena salvate.
bool mtimeUnreliable(String rel) => Platform.isWindows && isRegionFile(rel);

/// Scansiona [root] escludendo [exclusions]. [prior] è la cache della
/// scansione precedente. [onFile] è chiamato per ogni file incluso.
Future<ScanResult> scanTree(
  String root,
  Exclusions exclusions, {
  HashCache? prior,
  HashPool? pool,
  DateTime? now,
  void Function(String rel, bool hashed)? onFile,
}) async {
  final hp = pool ?? HashPool.shared;
  final old = prior?.entries ?? const {};
  final clock = now ?? DateTime.now();
  final files = <String, FileEntry>{};
  final cache = <String, CacheEntry>{};
  final unreadable = <String>[];
  final badNames = <String>[];
  final pending = <Future<void>>[];

  Future<void> hashOne(String rel, String osPath, int size0, DateTime modified0) async {
    var size = size0, modified = modified0;
    for (var attempt = 0; attempt < stableTries; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(Duration(milliseconds: 50 * attempt));
        final again = await FileStat.stat(osPath);
        if (again.type == FileSystemEntityType.notFound) return;
        size = again.size;
        modified = again.modified;
      }
      final FileHash r;
      try {
        r = await hp.file(osPath);
      } on FileSystemException {
        if (!await File(osPath).exists()) return; // cancellato durante la lettura
        // bloccato da un altro processo, antivirus, permessi: si salta
        unreadable.add(rel);
        return;
      }
      final after = await FileStat.stat(osPath);
      if (after.size == size && after.modified == modified && r.size == after.size) {
        final x = _execBit(rel, after, old[rel]);
        final mtime = after.modified.microsecondsSinceEpoch;
        final racy = clock.difference(after.modified) < racyWindow;
        cache[rel] = CacheEntry(
          size: r.size,
          mtime: mtime,
          h: r.h,
          chunks: r.chunks,
          x: x,
          racy: racy,
        );
        files[rel] = FileEntry(size: r.size, h: r.h, chunks: r.chunks, x: x);
        onFile?.call(rel, true);
        return;
      }
    }
    unreadable.add(rel);
  }

  // la visita (elenco, tipo e data di ogni file) gira in un altro isolate con
  // chiamate sincrone: sull'isolate dell'interfaccia ogni await aspetterebbe
  // il ciclo degli eventi, e su migliaia di file la scansione durava minuti
  final walked = await _walkInIsolate(root, exclusions);
  unreadable.addAll(walked.unreadable);
  badNames.addAll(walked.badNames);
  for (final f in walked.files) {
    final ce = old[f.rel];
    final reusable =
        ce != null &&
        ce.size == f.size &&
        ce.mtime == f.mtime &&
        !ce.racy &&
        (f.size < chunkThreshold || ce.chunks != null) &&
        !mtimeUnreliable(f.rel);
    if (reusable) {
      final x = _execBitMode(f.rel, f.mode, ce.size, ce.mtime, ce);
      final kept = CacheEntry(size: ce.size, mtime: ce.mtime, h: ce.h, chunks: ce.chunks, x: x);
      cache[f.rel] = kept;
      files[f.rel] = kept.entry;
      onFile?.call(f.rel, false);
    } else {
      pending.add(hashOne(f.rel, f.os, f.size, DateTime.fromMicrosecondsSinceEpoch(f.mtime)));
    }
  }
  await Future.wait(pending);

  // collisioni di maiuscole: si tiene il primo in ordine
  final caseDups = <String>[];
  final seen = <String>{};
  final ordered = files.keys.toList()..sort(comparePaths);
  for (final rel in ordered) {
    if (!seen.add(caseFoldKey(rel))) {
      caseDups.add(rel);
      files.remove(rel);
      cache.remove(rel);
    }
  }
  unreadable.sort(comparePaths);
  badNames.sort(comparePaths);
  return ScanResult(Manifest(files), HashCache(cache), unreadable, badNames, caseDups);
}

String _baseName(String p) {
  final sep = Platform.pathSeparator;
  var s = p;
  while (s.endsWith(sep) && s.length > 1) {
    s = s.substring(0, s.length - 1);
  }
  return s.substring(s.lastIndexOf(sep) + 1);
}

/// Bit di esecuzione: su Linux e macOS dal file system; su Windows (NTFS non
/// lo ha) si conserva quello noto se il file non è cambiato, altrimenti lo
/// si deduce dagli script .sh.
/// Come [_execBit], dai valori della visita.
bool _execBitMode(String rel, int mode, int size, int mtime, CacheEntry? prior) {
  if (!Platform.isWindows) return mode & 0x49 != 0; // 0o111
  if (prior != null && prior.size == size && prior.mtime == mtime) return prior.x;
  return rel.toLowerCase().endsWith('.sh');
}

bool _execBit(String rel, FileStat st, CacheEntry? prior) {
  if (!Platform.isWindows) return st.mode & 0x49 != 0; // 0o111
  if (prior != null && prior.size == st.size && prior.mtime == st.modified.microsecondsSinceEpoch) {
    return prior.x;
  }
  return rel.toLowerCase().endsWith('.sh');
}

/// [_walkSync] in un isolate. Funzione a sé: la closure cattura solo i due
/// argomenti (dentro [scanTree] si porterebbe dietro anche il pool, che non
/// si può inviare).
Future<_Walked> _walkInIsolate(String root, Exclusions exclusions) =>
    Isolate.run(() => _walkSync(root, exclusions));

/// Un file trovato dalla visita.
typedef _Found = ({String rel, String os, int size, int mtime, int mode});

/// Esito della visita sincrona.
typedef _Walked = ({List<_Found> files, List<String> unreadable, List<String> badNames});

/// Visita [root] con chiamate sincrone (gira in un isolate a parte): i file
/// inclusi con dimensione, data e permessi, le cartelle illeggibili e i nomi
/// non portabili. [ScanException] per una cartella che è un collegamento.
_Walked _walkSync(String root, Exclusions exclusions) {
  final files = <_Found>[];
  final unreadable = <String>[];
  final badNames = <String>[];

  void walk(String osDir, String relDir) {
    final List<FileSystemEntity> children;
    try {
      children = Directory(osDir).listSync(followLinks: false);
    } on FileSystemException {
      if (relDir.isEmpty) rethrow;
      unreadable.add('$relDir/');
      return;
    }
    for (final e in children) {
      final name = unorm.nfc(_baseName(e.path));
      if (name.isEmpty) continue;
      final rel = relDir.isEmpty ? name : '$relDir/$name';
      var type = FileSystemEntity.typeSync(e.path, followLinks: false);
      if (type == FileSystemEntityType.link) {
        final target = FileSystemEntity.typeSync(e.path);
        if (target == FileSystemEntityType.directory) {
          if (exclusions.excludesDir(rel)) continue;
          throw ScanException('dirSymlink', rel);
        }
        if (target != FileSystemEntityType.file) continue; // link rotto
        type = FileSystemEntityType.file;
      }
      if (type == FileSystemEntityType.directory) {
        if (exclusions.excludesDir(rel)) continue;
        walk(e.path, rel);
        continue;
      }
      if (type != FileSystemEntityType.file) continue; // fifo, socket, device
      if (exclusions.excludes(rel) || rel.endsWith(partSuffix)) continue;
      if (checkPath(rel) != null) {
        badNames.add(rel);
        continue;
      }
      final st = FileStat.statSync(e.path); // segue i link a file
      if (st.type == FileSystemEntityType.notFound) continue;
      files.add((
        rel: rel,
        os: e.path,
        size: st.size,
        mtime: st.modified.microsecondsSinceEpoch,
        mode: st.mode,
      ));
    }
  }

  walk(root, '');
  return (files: files, unreadable: unreadable, badNames: badNames);
}
