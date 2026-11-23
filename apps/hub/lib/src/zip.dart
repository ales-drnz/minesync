// Esportazione di una generazione come ZIP in streaming (B-SPACE-03).
//
// Le voci sono "stored" (non compresse): la lunghezza dell'archivio si
// conosce in anticipo dalle dimensioni del manifest e va in Content-Length.
// Il CRC-32 si calcola mentre i byte passano, quindi ogni voce ha il bit 3
// (data descriptor dopo i dati); le dimensioni vere sono comunque già
// nell'intestazione locale. ZIP64 solo dove serve (file ≥ 4 GiB, offset
// oltre 4 GiB, più di 65534 voci). Nomi in UTF-8 (bit 11), bit eseguibile
// negli attributi esterni Unix.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Una voce dell'archivio: il file [name] ricomposto dai blob [blobs] in
/// ordine (uno solo per i file non a pezzi).
final class ZipItem {
  const ZipItem({required this.name, required this.size, required this.blobs, this.exec = false})
    : data = null;

  /// Voce con i byte già in memoria (file generati, es. l'indice di un
  /// `.mrpack`).
  ZipItem.bytes({required this.name, required Uint8List this.data})
    : size = data.length,
      blobs = const [],
      exec = false;

  final String name;
  final int size;
  final List<String> blobs;
  final bool exec;
  final Uint8List? data;
}

const _max32 = 0xFFFFFFFF;

final class _Layout {
  _Layout(this.item, this.name, this.offset, this.zip64);
  final ZipItem item;
  final Uint8List name;
  final int offset;
  final bool zip64;
  int crc = 0;

  int get localLength => 30 + name.length + (zip64 ? 20 : 0);
  int get descriptorLength => zip64 ? 24 : 16;
  int get total => localLength + item.size + descriptorLength;
  bool get offset64 => offset >= _max32;
  int get centralExtra => zip64 || offset64 ? 4 + (zip64 ? 16 : 0) + (offset64 ? 8 : 0) : 0;
  int get centralLength => 46 + name.length + centralExtra;
}

/// Disposizione dell'archivio: [length] è esatta prima di scrivere un byte.
final class ZipPlan {
  /// [force64] usa ZIP64 per ogni voce e per la fine dell'archivio (test).
  ZipPlan(List<ZipItem> items, {DateTime? time, bool force64 = false}) : _force64 = force64 {
    final t = time ?? DateTime(1980);
    final y = t.year < 1980 ? 1980 : (t.year > 2107 ? 2107 : t.year);
    _dosDate = ((y - 1980) << 9) | (t.month << 5) | t.day;
    _dosTime = (t.hour << 11) | (t.minute << 5) | (t.second ~/ 2);
    var off = 0;
    for (final it in items) {
      final l = _Layout(
        it,
        Uint8List.fromList(utf8.encode(it.name)),
        off,
        force64 || it.size >= _max32 || off >= _max32,
      );
      _entries.add(l);
      off += l.total;
    }
    _cdOffset = off;
    _cdSize = _entries.fold(0, (a, l) => a + l.centralLength);
    _end64 = force64 || _entries.length >= 0xFFFF || _cdOffset >= _max32 || _cdSize >= _max32;
    length = _cdOffset + _cdSize + (_end64 ? 56 + 20 : 0) + 22;
  }

  final bool _force64;
  final _entries = <_Layout>[];
  late final int _dosDate;
  late final int _dosTime;
  late final int _cdOffset;
  late final int _cdSize;
  late final bool _end64;

  /// Byte totali dell'archivio.
  late final int length;

  /// Vero se l'archivio usa ZIP64 da qualche parte.
  bool get usesZip64 => _end64 || _entries.any((l) => l.zip64 || l.offset64);

  /// Scrive l'archivio su [out] leggendo i blob da [pathOf]. Lancia
  /// [FileSystemException] o [StateError] se un blob manca o cambia
  /// dimensione a metà (la risposta resta troncata: Content-Length lo dice).
  Future<void> write(IOSink out, String Function(String hash) pathOf) async {
    for (final l in _entries) {
      out.add(_local(l));
      final crc = Crc32();
      var n = 0;
      if (l.item.data case final d?) {
        crc.add(d);
        n += d.length;
        out.add(d);
      }
      for (final h in l.item.blobs) {
        await out.addStream(
          File(pathOf(h)).openRead().map((c) {
            crc.add(c);
            n += c.length;
            return c;
          }),
        );
      }
      if (n != l.item.size) {
        throw StateError('${l.item.name}: ${l.item.size} byte attesi, $n letti');
      }
      l.crc = crc.value;
      out.add(_descriptor(l));
    }
    final cd = BytesBuilder(copy: false);
    for (final l in _entries) {
      cd.add(_central(l));
    }
    out.add(cd.takeBytes());
    out.add(_end());
  }

  int get _flags => 0x0008 | 0x0800;

  Uint8List _local(_Layout l) {
    final b = ByteData(l.localLength);
    final size = l.item.size;
    b
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, l.zip64 ? 45 : 20, Endian.little)
      ..setUint16(6, _flags, Endian.little)
      ..setUint16(8, 0, Endian.little) // stored
      ..setUint16(10, _dosTime, Endian.little)
      ..setUint16(12, _dosDate, Endian.little)
      ..setUint32(14, 0, Endian.little) // crc nel data descriptor
      ..setUint32(18, l.zip64 ? _max32 : size, Endian.little)
      ..setUint32(22, l.zip64 ? _max32 : size, Endian.little)
      ..setUint16(26, l.name.length, Endian.little)
      ..setUint16(28, l.zip64 ? 20 : 0, Endian.little);
    final u = b.buffer.asUint8List()..setRange(30, 30 + l.name.length, l.name);
    if (l.zip64) {
      final o = 30 + l.name.length;
      b
        ..setUint16(o, 0x0001, Endian.little)
        ..setUint16(o + 2, 16, Endian.little)
        ..setUint64(o + 4, size, Endian.little)
        ..setUint64(o + 12, size, Endian.little);
    }
    return u;
  }

  Uint8List _descriptor(_Layout l) {
    final b = ByteData(l.descriptorLength)
      ..setUint32(0, 0x08074b50, Endian.little)
      ..setUint32(4, l.crc, Endian.little);
    if (l.zip64) {
      b
        ..setUint64(8, l.item.size, Endian.little)
        ..setUint64(16, l.item.size, Endian.little);
    } else {
      b
        ..setUint32(8, l.item.size, Endian.little)
        ..setUint32(12, l.item.size, Endian.little);
    }
    return b.buffer.asUint8List();
  }

  Uint8List _central(_Layout l) {
    final b = ByteData(l.centralLength);
    final size = l.item.size;
    final mode = l.item.exec ? 0x81ed : 0x81a4; // 0100755 / 0100644
    b
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, (3 << 8) | 45, Endian.little) // Unix, 4.5
      ..setUint16(6, l.zip64 || l.offset64 ? 45 : 20, Endian.little)
      ..setUint16(8, _flags, Endian.little)
      ..setUint16(10, 0, Endian.little)
      ..setUint16(12, _dosTime, Endian.little)
      ..setUint16(14, _dosDate, Endian.little)
      ..setUint32(16, l.crc, Endian.little)
      ..setUint32(20, l.zip64 ? _max32 : size, Endian.little)
      ..setUint32(24, l.zip64 ? _max32 : size, Endian.little)
      ..setUint16(28, l.name.length, Endian.little)
      ..setUint16(30, l.centralExtra, Endian.little)
      ..setUint16(32, 0, Endian.little) // commento
      ..setUint16(34, 0, Endian.little) // disco
      ..setUint16(36, 0, Endian.little) // attributi interni
      ..setUint32(38, mode << 16, Endian.little)
      ..setUint32(42, l.offset64 ? _max32 : l.offset, Endian.little);
    final u = b.buffer.asUint8List()..setRange(46, 46 + l.name.length, l.name);
    if (l.centralExtra > 0) {
      var o = 46 + l.name.length;
      b
        ..setUint16(o, 0x0001, Endian.little)
        ..setUint16(o + 2, l.centralExtra - 4, Endian.little);
      o += 4;
      if (l.zip64) {
        b
          ..setUint64(o, size, Endian.little)
          ..setUint64(o + 8, size, Endian.little);
        o += 16;
      }
      if (l.offset64) b.setUint64(o, l.offset, Endian.little);
    }
    return u;
  }

  Uint8List _end() {
    final n = _entries.length;
    final b = ByteData((_end64 ? 56 + 20 : 0) + 22);
    var o = 0;
    if (_end64) {
      b
        ..setUint32(0, 0x06064b50, Endian.little)
        ..setUint64(4, 44, Endian.little)
        ..setUint16(12, (3 << 8) | 45, Endian.little)
        ..setUint16(14, 45, Endian.little)
        ..setUint32(16, 0, Endian.little)
        ..setUint32(20, 0, Endian.little)
        ..setUint64(24, n, Endian.little)
        ..setUint64(32, n, Endian.little)
        ..setUint64(40, _cdSize, Endian.little)
        ..setUint64(48, _cdOffset, Endian.little)
        // locator
        ..setUint32(56, 0x07064b50, Endian.little)
        ..setUint32(60, 0, Endian.little)
        ..setUint64(64, _cdOffset + _cdSize, Endian.little)
        ..setUint32(72, 1, Endian.little);
      o = 76;
    }
    final many = _end64 && (_force64 || n >= 0xFFFF);
    b
      ..setUint32(o, 0x06054b50, Endian.little)
      ..setUint16(o + 4, 0, Endian.little)
      ..setUint16(o + 6, 0, Endian.little)
      ..setUint16(o + 8, many ? 0xFFFF : n, Endian.little)
      ..setUint16(o + 10, many ? 0xFFFF : n, Endian.little)
      ..setUint32(o + 12, _end64 ? _max32 : _cdSize, Endian.little)
      ..setUint32(o + 16, _end64 ? _max32 : _cdOffset, Endian.little)
      ..setUint16(o + 20, 0, Endian.little);
    return b.buffer.asUint8List();
  }
}

/// CRC-32 (IEEE 802.3, quello di ZIP e gzip), a otto tabelle.
final class Crc32 {
  int _c = 0xFFFFFFFF;

  static final List<Uint32List> _t = () {
    final t = List.generate(8, (_) => Uint32List(256));
    for (var i = 0; i < 256; i++) {
      var c = i;
      for (var k = 0; k < 8; k++) {
        c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
      }
      t[0][i] = c;
    }
    for (var i = 0; i < 256; i++) {
      var c = t[0][i];
      for (var k = 1; k < 8; k++) {
        c = t[0][c & 0xff] ^ (c >> 8);
        t[k][i] = c;
      }
    }
    return t;
  }();

  void add(List<int> data) {
    final t0 = _t[0], t1 = _t[1], t2 = _t[2], t3 = _t[3];
    final t4 = _t[4], t5 = _t[5], t6 = _t[6], t7 = _t[7];
    var c = _c;
    var i = 0;
    final n = data.length;
    for (; i + 8 <= n; i += 8) {
      final a = c ^ (data[i] | data[i + 1] << 8 | data[i + 2] << 16 | data[i + 3] << 24);
      c =
          t7[a & 0xff] ^
          t6[(a >> 8) & 0xff] ^
          t5[(a >> 16) & 0xff] ^
          t4[(a >> 24) & 0xff] ^
          t3[data[i + 4]] ^
          t2[data[i + 5]] ^
          t1[data[i + 6]] ^
          t0[data[i + 7]];
    }
    for (; i < n; i++) {
      c = t0[(c ^ data[i]) & 0xff] ^ (c >> 8);
    }
    _c = c;
  }

  int get value => (_c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
