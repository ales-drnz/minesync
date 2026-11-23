// Manifest di una generazione: mappa percorso → voce, con un digest
// canonico che client e hub calcolano byte per byte allo stesso modo.
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

import 'paths.dart';

final _hashRe = RegExp(r'^[0-9a-f]{64}$');

/// Vero se [h] è uno SHA-256 esadecimale minuscolo.
bool isHash(String h) => _hashRe.hasMatch(h);

/// Soglia oltre la quale un file viene diviso in chunk (2 MiB).
const int chunkThreshold = 2 << 20;

/// Un pezzo di un file grande.
final class Chunk {
  const Chunk(this.h, this.size);

  factory Chunk.fromJson(Object? json) {
    final m = _map(json, 'chunk');
    return Chunk(_hash(m['h'], 'chunk.h'), _size(m['size'], 'chunk.size'));
  }

  final String h;
  final int size;

  Map<String, Object> toJson() => {'h': h, 'size': size};

  @override
  bool operator ==(Object other) => other is Chunk && other.h == h && other.size == size;

  @override
  int get hashCode => Object.hash(h, size);
}

/// Una voce del manifest.
final class FileEntry {
  FileEntry({required this.size, required this.h, List<Chunk>? chunks, this.x = false})
    : chunks = chunks == null ? null : List.unmodifiable(chunks) {
    if (size < 0) throw const FormatException('dimensione negativa');
    if (!isHash(h)) throw FormatException('hash non valido: $h');
    final c = this.chunks;
    if (c != null) {
      if (c.isEmpty) throw const FormatException('lista di chunk vuota');
      var sum = 0;
      for (final k in c) {
        sum += k.size;
      }
      if (sum != size) throw const FormatException('la somma dei chunk non è la dimensione');
    }
  }

  factory FileEntry.fromJson(Object? json) {
    final m = _map(json, 'entry');
    final c = m['chunks'];
    return FileEntry(
      size: _size(m['size'], 'size'),
      h: _hash(m['h'], 'h'),
      chunks: c == null ? null : [for (final k in _list(c, 'chunks')) Chunk.fromJson(k)],
      x: m['x'] == true,
    );
  }

  final int size;

  /// SHA-256 dell'intero file.
  final String h;

  /// Chunk del file, o null se il file è un blob unico ([h]).
  final List<Chunk>? chunks;

  /// Bit di esecuzione.
  final bool x;

  /// Blob che servono a ricostruire il file.
  Iterable<String> get blobs => chunks?.map((c) => c.h) ?? [h];

  /// Stesso contenuto (ignora come è stato diviso in chunk).
  bool sameContent(FileEntry o) => o.h == h && o.size == size && o.x == x;

  /// Codifica canonica: chiavi nell'ordine fisso size, h, chunks, x.
  Map<String, Object> toJson() => {
    'size': size,
    'h': h,
    if (chunks != null) 'chunks': [for (final c in chunks!) c.toJson()],
    if (x) 'x': true,
  };

  @override
  bool operator ==(Object other) =>
      other is FileEntry &&
      other.size == size &&
      other.h == h &&
      other.x == x &&
      _sameChunks(other.chunks, chunks);

  @override
  int get hashCode => Object.hash(size, h, x);
}

bool _sameChunks(List<Chunk>? a, List<Chunk>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Manifest immutabile, ordinato per percorso (ordine dei byte UTF-8).
final class Manifest {
  Manifest._(this._files);

  /// Costruisce un manifest validando ogni percorso e le collisioni di
  /// maiuscole/minuscole. Lancia [ManifestError] al primo problema.
  factory Manifest(Map<String, FileEntry> files) {
    final sorted = SplayTreeMap<String, FileEntry>(comparePaths);
    for (final e in files.entries) {
      final p = checkPath(e.key);
      if (p != null) throw ManifestError(e.key, p.name);
      sorted[e.key] = e.value;
    }
    final c = caseCollisions(sorted.keys);
    if (c.isNotEmpty) throw ManifestError(c.first.$2, 'caseCollision');
    return Manifest._(UnmodifiableMapView(sorted));
  }

  factory Manifest.fromJson(Object? json) {
    final m = _map(json, 'manifest');
    return Manifest({for (final e in m.entries) e.key: FileEntry.fromJson(e.value)});
  }

  static final Manifest empty = Manifest._(const {});

  final Map<String, FileEntry> _files;

  Map<String, FileEntry> get files => _files;
  int get length => _files.length;
  bool get isEmpty => _files.isEmpty;
  FileEntry? operator [](String path) => _files[path];

  /// Somma delle dimensioni dei file.
  int get totalSize => _files.values.fold(0, (a, e) => a + e.size);

  /// Tutti i blob referenziati (senza duplicati).
  Set<String> get blobs => {for (final e in _files.values) ...e.blobs};

  Map<String, Object> toJson() => {for (final e in _files.entries) e.key: e.value.toJson()};

  /// Byte canonici: oggetto JSON senza spazi, voci in ordine di percorso.
  List<int> canonicalBytes() => utf8.encode(jsonEncode(toJson()));

  /// SHA-256 dei byte canonici: l'identità di una generazione.
  String digest() => crypto.sha256.convert(canonicalBytes()).toString();
}

/// Un percorso del manifest non valido.
final class ManifestError implements Exception {
  const ManifestError(this.path, this.reason);
  final String path;
  final String reason;
  @override
  String toString() => 'ManifestError($reason): $path';
}

/// Differenze tra due manifest.
final class ManifestDiff {
  ManifestDiff(Manifest from, Manifest to)
    : added = [
        for (final p in to.files.keys)
          if (from[p] == null) p,
      ],
      removed = [
        for (final p in from.files.keys)
          if (to[p] == null) p,
      ],
      changed = [
        for (final e in to.files.entries)
          if (from[e.key] case final old? when !old.sameContent(e.value)) e.key,
      ];

  final List<String> added;
  final List<String> removed;
  final List<String> changed;

  bool get isEmpty => added.isEmpty && removed.isEmpty && changed.isEmpty;
}

Map<String, Object?> _map(Object? v, String what) =>
    v is Map<String, Object?> ? v : throw FormatException('$what: atteso un oggetto');

List<Object?> _list(Object? v, String what) =>
    v is List<Object?> ? v : throw FormatException('$what: attesa una lista');

String _hash(Object? v, String what) =>
    v is String && isHash(v) ? v : throw FormatException('$what: hash non valido');

int _size(Object? v, String what) =>
    v is int && v >= 0 ? v : throw FormatException('$what: dimensione non valida');
