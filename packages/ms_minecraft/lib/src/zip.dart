// Lettura di archivi zip (jar delle mod) ad accesso casuale: solo la
// directory centrale e le voci richieste, mai l'intero file. La sorgente dei
// byte è astratta, così l'hub legge un jar diviso in chunk senza
// ricomporlo. Niente ZIP64 né cifratura: voci che non tornano si ignorano.
//
// Ogni decompressione ha un tetto sui byte prodotti: un archivio ostile non
// può far crescere la memoria oltre quel limite.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

/// Byte leggibili a caso, per offset.
abstract interface class ByteSource {
  /// Dimensione totale.
  int get length;

  /// Al più [length] byte da [offset] (meno solo a fine sorgente).
  Future<Uint8List> read(int offset, int length);
}

/// Sorgente in memoria.
final class BytesSource implements ByteSource {
  BytesSource(this.bytes);
  final Uint8List bytes;

  @override
  int get length => bytes.length;

  @override
  Future<Uint8List> read(int offset, int length) async {
    if (offset < 0 || offset >= bytes.length || length <= 0) return Uint8List(0);
    return Uint8List.sublistView(bytes, offset, math.min(bytes.length, offset + length));
  }
}

/// Byte prodotti oltre il tetto di una decompressione.
final class _TooLarge implements Exception {
  const _TooLarge();
}

final class _CappedSink implements Sink<List<int>> {
  _CappedSink(this.max);
  final int max;
  final out = BytesBuilder(copy: false);

  @override
  void add(List<int> data) {
    if (out.length + data.length > max) throw const _TooLarge();
    out.add(data);
  }

  @override
  void close() {}
}

/// Formato della compressione per [inflate].
enum Compression { raw, zlib, gzip }

/// Decomprime [data] producendo al più [max] byte. Lancia [FormatException]
/// se i dati sono rotti o se si supera [max].
Uint8List inflate(Uint8List data, {required int max, Compression format = Compression.raw}) {
  final sink = _CappedSink(max);
  final dec = switch (format) {
    Compression.raw => ZLibDecoder(raw: true),
    Compression.zlib => ZLibDecoder(),
    Compression.gzip => GZipCodec().decoder,
  };
  try {
    final conv = dec.startChunkedConversion(sink);
    // a pezzi: il tetto scatta presto anche su una bomba di decompressione
    const step = 64 << 10;
    for (var i = 0; i < data.length; i += step) {
      conv.add(Uint8List.sublistView(data, i, math.min(data.length, i + step)));
    }
    conv.close();
  } on _TooLarge {
    throw FormatException('decompressed data larger than $max bytes');
  } on FormatException {
    rethrow;
  } on Object catch (e) {
    // ZLibDecoder segnala i dati rotti con FileSystemException o simili
    throw FormatException('invalid compressed data ($e)');
  }
  return sink.out.takeBytes();
}

/// Una voce della directory centrale.
final class ZipEntry {
  const ZipEntry._(this.name, this.method, this.compressedSize, this.size, this._localOffset);

  final String name;

  /// 0 = stored, 8 = deflate; altri metodi non si leggono.
  final int method;
  final int compressedSize;
  final int size;
  final int _localOffset;

  bool get isDirectory => name.endsWith('/');
}

/// Indice di un archivio zip.
final class ZipArchive {
  ZipArchive._(this._src, this.entries);

  final ByteSource _src;

  /// Voci per nome, nell'ordine della directory centrale.
  final Map<String, ZipEntry> entries;

  /// Tetto alla directory centrale e al numero di voci.
  static const maxDirectory = 16 << 20;
  static const maxEntries = 200000;

  /// Legge la directory centrale di [src]; null se non è uno zip leggibile.
  static Future<ZipArchive?> open(ByteSource src) async {
    try {
      final len = src.length;
      if (len < 22) return null;
      final tailLen = math.min(len, 22 + 65535);
      final tail = await src.read(len - tailLen, tailLen);
      var eocd = -1;
      for (var i = tail.length - 22; i >= 0; i--) {
        if (tail[i] == 0x50 && tail[i + 1] == 0x4B && tail[i + 2] == 0x05 && tail[i + 3] == 0x06) {
          eocd = i;
          break;
        }
      }
      if (eocd < 0) return null;
      final t = ByteData.sublistView(tail);
      final cdSize = t.getUint32(eocd + 12, Endian.little);
      final cdOffset = t.getUint32(eocd + 16, Endian.little);
      if (cdSize > maxDirectory || cdOffset + cdSize > len) return null;
      final cd = await src.read(cdOffset, cdSize);
      if (cd.length != cdSize) return null;
      final c = ByteData.sublistView(cd);
      final out = <String, ZipEntry>{};
      var p = 0;
      while (p + 46 <= cd.length && c.getUint32(p, Endian.little) == 0x02014b50) {
        if (out.length >= maxEntries) return null;
        final flags = c.getUint16(p + 8, Endian.little);
        final method = c.getUint16(p + 10, Endian.little);
        final compSize = c.getUint32(p + 20, Endian.little);
        final size = c.getUint32(p + 24, Endian.little);
        final nameLen = c.getUint16(p + 28, Endian.little);
        final extraLen = c.getUint16(p + 30, Endian.little);
        final commentLen = c.getUint16(p + 32, Endian.little);
        final local = c.getUint32(p + 42, Endian.little);
        if (p + 46 + nameLen > cd.length) return null;
        final name = utf8.decode(
          Uint8List.sublistView(cd, p + 46, p + 46 + nameLen),
          allowMalformed: true,
        );
        // cifrate (bit 0) o ZIP64 (0xFFFFFFFF): non si leggono
        if (flags & 1 == 0 && compSize != 0xFFFFFFFF && size != 0xFFFFFFFF && local != 0xFFFFFFFF) {
          out.putIfAbsent(name, () => ZipEntry._(name, method, compSize, size, local));
        }
        p += 46 + nameLen + extraLen + commentLen;
      }
      return ZipArchive._(src, out);
    } on Object {
      return null;
    }
  }

  ZipEntry? operator [](String name) => entries[name];

  /// La voce [name] senza distinguere maiuscole (i percorsi delle icone nei
  /// metadati non sempre rispettano quelle del jar).
  ZipEntry? find(String name) {
    final e = entries[name];
    if (e != null) return e;
    final low = name.toLowerCase();
    for (final x in entries.values) {
      if (x.name.toLowerCase() == low) return x;
    }
    return null;
  }

  /// Contenuto di [e] se al più [max] byte, altrimenti (o se illeggibile)
  /// null.
  Future<Uint8List?> read(ZipEntry e, {int max = 1 << 20}) async {
    if (e.size > max || e.compressedSize > max + (max >> 3) + 1024) return null;
    try {
      final lh = await _src.read(e._localOffset, 30);
      if (lh.length < 30) return null;
      final l = ByteData.sublistView(lh);
      if (l.getUint32(0, Endian.little) != 0x04034b50) return null;
      final skip = l.getUint16(26, Endian.little) + l.getUint16(28, Endian.little);
      final data = await _src.read(e._localOffset + 30 + skip, e.compressedSize);
      if (data.length != e.compressedSize) return null;
      return switch (e.method) {
        0 => data.length <= max ? data : null,
        8 => inflate(data, max: max),
        _ => null,
      };
    } on Object {
      return null;
    }
  }

  /// Come [read] per nome.
  Future<Uint8List?> readNamed(String name, {int max = 1 << 20}) async {
    final e = entries[name];
    return e == null ? null : read(e, max: max);
  }
}
