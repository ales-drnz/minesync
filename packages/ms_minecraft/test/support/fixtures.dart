// Strumenti comuni ai test: cartelle temporanee con layout di server pack
// e jar minimi.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Cartella temporanea cancellata a fine test.
String tempDir() {
  final d = Directory.systemTemp.createTempSync('ms_minecraft_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d.resolveSymbolicLinksSync();
}

/// Scrive [files] (percorso con `/` → contenuto) sotto [dir]. I percorsi in
/// [executable] ricevono il bit di esecuzione (solo POSIX).
String mk(String dir, Map<String, Object> files, {Set<String> executable = const {}}) {
  for (final MapEntry(key: rel, value: content) in files.entries) {
    final full = p.joinAll([dir, ...rel.split('/')]);
    if (rel.endsWith('/')) {
      Directory(full).createSync(recursive: true);
      continue;
    }
    File(full).parent.createSync(recursive: true);
    switch (content) {
      case final String s:
        File(full).writeAsStringSync(s);
      case final List<int> b:
        File(full).writeAsBytesSync(b);
      default:
        throw ArgumentError('contenuto non supportato per $rel');
    }
    if (executable.contains(rel) && !Platform.isWindows) {
      Process.runSync('chmod', ['755', full]);
    }
  }
  return dir;
}

/// Jar (zip) minimo con gli elementi dati (testo o byte), compressi o no.
Uint8List zipBytes(Map<String, Object> entries, {bool deflate = true}) {
  final out = BytesBuilder();
  final central = BytesBuilder();
  var count = 0;
  for (final MapEntry(key: name, value: content) in entries.entries) {
    final raw = content is String ? utf8.encode(content) : content as List<int>;
    final data = deflate ? ZLibEncoder(raw: true).convert(raw) : raw;
    final nameBytes = utf8.encode(name);
    final offset = out.length;
    final local = ByteData(30)
      ..setUint32(0, 0x04034b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(8, deflate ? 8 : 0, Endian.little)
      ..setUint32(18, data.length, Endian.little)
      ..setUint32(22, raw.length, Endian.little)
      ..setUint16(26, nameBytes.length, Endian.little);
    out
      ..add(local.buffer.asUint8List())
      ..add(nameBytes)
      ..add(data);
    final cd = ByteData(46)
      ..setUint32(0, 0x02014b50, Endian.little)
      ..setUint16(4, 20, Endian.little)
      ..setUint16(6, 20, Endian.little)
      ..setUint16(10, deflate ? 8 : 0, Endian.little)
      ..setUint32(20, data.length, Endian.little)
      ..setUint32(24, raw.length, Endian.little)
      ..setUint16(28, nameBytes.length, Endian.little)
      ..setUint32(42, offset, Endian.little);
    central
      ..add(cd.buffer.asUint8List())
      ..add(nameBytes);
    count++;
  }
  final cdOffset = out.length;
  final cdBytes = central.takeBytes();
  out.add(cdBytes);
  final eocd = ByteData(22)
    ..setUint32(0, 0x06054b50, Endian.little)
    ..setUint16(8, count, Endian.little)
    ..setUint16(10, count, Endian.little)
    ..setUint32(12, cdBytes.length, Endian.little)
    ..setUint32(16, cdOffset, Endian.little);
  out.add(eocd.buffer.asUint8List());
  return out.takeBytes();
}

int _crc32(List<int> data) {
  var c = 0xffffffff;
  for (final b in data) {
    c ^= b;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? (c >> 1) ^ 0xedb88320 : c >> 1;
    }
  }
  return c ^ 0xffffffff;
}

/// PNG valido di 1×1 pixel (generato qui: nessuna immagine esterna).
Uint8List tinyPng() {
  final out = BytesBuilder()..add([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final t = ascii.encode(type);
    out
      ..add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List())
      ..add(t)
      ..add(data)
      ..add((ByteData(4)..setUint32(0, _crc32([...t, ...data]))).buffer.asUint8List());
  }

  chunk('IHDR', [0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert([0, 0x55, 0xAA, 0x55, 0xFF]));
  chunk('IEND', const []);
  return out.takeBytes();
}
