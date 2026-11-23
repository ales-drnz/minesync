// Lettore NBT (formato Java, big-endian) per level.dat e simili. Il file
// arriva dall'hub o dal disco ed è trattato come ostile (B-META-04): l'unica
// eccezione possibile è FormatException, la profondità e il numero di nodi
// hanno un tetto, ogni lunghezza dichiarata è confrontata con i byte rimasti
// prima di allocare qualsiasi cosa.
//
// Valori: compound → Map<String, Object?> (in ordine), list → List<Object?>,
// byte/short/int/long → int, float/double → double, string → String,
// byte array → Uint8List, int array → Int32List, long array → Int64List.
import 'dart:convert';
import 'dart:typed_data';

import 'zip.dart';

/// Tetti di sicurezza: un level.dat vero ha qualche migliaio di nodi
/// (decine di migliaia con i registri delle mod).
const nbtMaxBytes = 16 << 20;
const nbtMaxNodes = 1 << 18;
const nbtMaxDepth = 512;

/// Decodifica un documento NBT: gzip, zlib o non compresso (riconosciuti dai
/// primi byte). Restituisce il compound radice. Lancia solo
/// [FormatException].
Map<String, Object?> readNbt(
  Uint8List data, {
  int maxBytes = nbtMaxBytes,
  int maxNodes = nbtMaxNodes,
}) {
  Uint8List raw;
  if (data.length >= 2 && data[0] == 0x1f && data[1] == 0x8b) {
    raw = inflate(data, max: maxBytes, format: Compression.gzip);
  } else if (data.length >= 2 && data[0] == 0x78 && ((data[0] << 8) | data[1]) % 31 == 0) {
    raw = inflate(data, max: maxBytes, format: Compression.zlib);
  } else {
    if (data.length > maxBytes) throw FormatException('NBT larger than $maxBytes bytes');
    raw = data;
  }
  return _NbtReader(raw, maxNodes).root();
}

final class _NbtReader {
  _NbtReader(this.b, this.maxNodes) : d = ByteData.sublistView(b);

  final Uint8List b;
  final ByteData d;
  final int maxNodes;
  int pos = 0;
  int nodes = 0;

  int get left => b.length - pos;

  void _need(int n) {
    if (n < 0 || n > left) throw FormatException('NBT truncated at byte $pos');
  }

  int u8() {
    _need(1);
    return b[pos++];
  }

  int i32() {
    _need(4);
    final v = d.getInt32(pos);
    pos += 4;
    return v;
  }

  String str() {
    _need(2);
    final n = d.getUint16(pos);
    pos += 2;
    _need(n);
    // Java usa un UTF-8 "modificato": per i nomi che servono basta quello vero
    final s = utf8.decode(Uint8List.sublistView(b, pos, pos + n), allowMalformed: true);
    pos += n;
    return s;
  }

  Map<String, Object?> root() {
    final t = u8();
    if (t != 10) throw const FormatException('NBT root is not a compound');
    str(); // nome della radice, di solito vuoto
    final v = payload(10, 0);
    return v! as Map<String, Object?>;
  }

  /// Byte minimi del payload di un tag di tipo [t] (per controllare le
  /// liste prima di allocarle).
  static int _minSize(int t) => switch (t) {
    1 => 1,
    2 => 2,
    3 || 5 => 4,
    4 || 6 => 8,
    7 || 9 || 11 || 12 => 4,
    8 => 2,
    10 => 1,
    _ => 0,
  };

  Object? payload(int t, int depth) {
    if (depth > nbtMaxDepth) throw const FormatException('NBT nested too deeply');
    if (++nodes > maxNodes) throw const FormatException('NBT has too many nodes');
    switch (t) {
      case 1:
        _need(1);
        return d.getInt8(pos++);
      case 2:
        _need(2);
        final v = d.getInt16(pos);
        pos += 2;
        return v;
      case 3:
        return i32();
      case 4:
        _need(8);
        final v = d.getInt64(pos);
        pos += 8;
        return v;
      case 5:
        _need(4);
        final v = d.getFloat32(pos);
        pos += 4;
        return v;
      case 6:
        _need(8);
        final v = d.getFloat64(pos);
        pos += 8;
        return v;
      case 7:
        final n = i32();
        _need(n);
        final v = Uint8List.fromList(Uint8List.sublistView(b, pos, pos + n));
        pos += n;
        return v;
      case 8:
        return str();
      case 9:
        final et = u8();
        final n = i32();
        if (n < 0) throw const FormatException('NBT list with negative length');
        if (n == 0) return const <Object?>[];
        if (et == 0 || et > 12) throw FormatException('NBT list of invalid type $et');
        // una lista che dichiara più elementi dei byte rimasti è rifiutata
        // prima di allocare
        if (n > left ~/ _minSize(et)) throw const FormatException('NBT list longer than the data');
        if (nodes + n > maxNodes) throw const FormatException('NBT has too many nodes');
        final out = <Object?>[];
        for (var i = 0; i < n; i++) {
          out.add(payload(et, depth + 1));
        }
        return out;
      case 10:
        final out = <String, Object?>{};
        while (true) {
          final ct = u8();
          if (ct == 0) return out;
          if (ct > 12) throw FormatException('NBT tag of invalid type $ct');
          final name = str();
          out[name] = payload(ct, depth + 1);
        }
      case 11:
        final n = i32();
        if (n < 0 || n > left ~/ 4) {
          throw const FormatException('NBT int array longer than the data');
        }
        final v = Int32List(n);
        for (var i = 0; i < n; i++) {
          v[i] = d.getInt32(pos + 4 * i);
        }
        pos += 4 * n;
        return v;
      case 12:
        final n = i32();
        if (n < 0 || n > left ~/ 8) {
          throw const FormatException('NBT long array longer than the data');
        }
        final v = Int64List(n);
        for (var i = 0; i < n; i++) {
          v[i] = d.getInt64(pos + 8 * i);
        }
        pos += 8 * n;
        return v;
    }
    throw FormatException('NBT tag of invalid type $t');
  }
}

/// Costruttore di documenti NBT non compressi (test e fixture).
final class NbtWriter {
  final _b = BytesBuilder();

  Uint8List takeBytes() => _b.takeBytes();

  void _u16(int v) => _b.add([(v >> 8) & 0xff, v & 0xff]);
  void _i32(int v) => _b.add((ByteData(4)..setInt32(0, v)).buffer.asUint8List());
  void _i64(int v) => _b.add((ByteData(8)..setInt64(0, v)).buffer.asUint8List());

  void _name(int t, String name) {
    _b.addByte(t);
    final n = utf8.encode(name);
    _u16(n.length);
    _b.add(n);
  }

  /// Apre un compound (anche la radice, con nome vuoto).
  void begin(String name) => _name(10, name);
  void end() => _b.addByte(0);
  void byte(String name, int v) {
    _name(1, name);
    _b.addByte(v & 0xff);
  }

  void short(String name, int v) {
    _name(2, name);
    _u16(v & 0xffff);
  }

  void int32(String name, int v) {
    _name(3, name);
    _i32(v);
  }

  void int64(String name, int v) {
    _name(4, name);
    _i64(v);
  }

  void string(String name, String v) {
    _name(8, name);
    final n = utf8.encode(v);
    _u16(n.length);
    _b.add(n);
  }

  void intArray(String name, List<int> v) {
    _name(11, name);
    _i32(v.length);
    for (final x in v) {
      _i32(x);
    }
  }

  /// Lista di int.
  void intList(String name, List<int> v) {
    _name(9, name);
    _b.addByte(3);
    _i32(v.length);
    for (final x in v) {
      _i32(x);
    }
  }

  /// Byte grezzi (per costruire input malformati nei test).
  void raw(List<int> bytes) => _b.add(bytes);
}
