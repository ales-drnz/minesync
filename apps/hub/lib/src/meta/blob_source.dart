// Lettura di un file del manifest dai blob dello store: un file può essere
// un blob unico o una lista di chunk. Si legge solo ciò che serve, a pezzi,
// senza ricomporre il file su disco.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ms_minecraft/ms_minecraft.dart' show ByteSource;
import 'package:ms_protocol/ms_protocol.dart';

import '../blobs.dart';

/// Il file [entry] come sorgente ad accesso casuale.
final class ManifestFileSource implements ByteSource {
  ManifestFileSource(this._blobs, this.entry) {
    final c = entry.chunks;
    if (c == null) {
      _parts = [(h: entry.h, start: 0, size: entry.size)];
    } else {
      var off = 0;
      _parts = [for (final k in c) (h: k.h, start: (off += k.size) - k.size, size: k.size)];
    }
  }

  final BlobStore _blobs;
  final FileEntry entry;
  late final List<({String h, int start, int size})> _parts;

  @override
  int get length => entry.size;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || length <= 0 || offset >= entry.size) return Uint8List(0);
    final end = math.min(entry.size, offset + length);
    final out = Uint8List(end - offset);
    var filled = 0;
    for (final p in _parts) {
      final pEnd = p.start + p.size;
      if (pEnd <= offset || p.start >= end) continue;
      final from = math.max(offset, p.start) - p.start;
      final to = math.min(end, pEnd) - p.start;
      final raf = await File(_blobs.pathOf(p.h)).open();
      try {
        await raf.setPosition(from);
        final got = await raf.readInto(out, filled, filled + (to - from));
        if (got != to - from) throw FileSystemException('blob shorter than expected', p.h);
        filled += got;
      } finally {
        await raf.close();
      }
    }
    return out;
  }
}

/// L'intero file [entry] se al più [max] byte; null se più grande o se un
/// blob manca o è illeggibile.
Future<Uint8List?> readManifestFile(BlobStore blobs, FileEntry? entry, {required int max}) async {
  if (entry == null || entry.size > max) return null;
  try {
    final b = await ManifestFileSource(blobs, entry).read(0, entry.size);
    return b.length == entry.size ? b : null;
  } on FileSystemException {
    return null;
  }
}
