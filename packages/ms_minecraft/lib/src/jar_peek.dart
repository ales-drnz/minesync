// Lettura minima di un jar (zip) per estrarre UN file piccolo, senza
// dipendenze: serve solo version.json dentro il server jar di Mojang.
// Niente ZIP64, niente cifratura: un jar che non torna si ignora.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const _maxEntry = 1 << 20;

/// Contenuto dell'elemento [name] del jar [jarPath], o null.
Uint8List? readJarEntry(String jarPath, String name) {
  RandomAccessFile? raf;
  try {
    raf = File(jarPath).openSync();
    final len = raf.lengthSync();
    if (len < 22) return null;
    // fine della directory centrale: negli ultimi 22 + 65535 byte
    final tailLen = len < 22 + 65535 ? len : 22 + 65535;
    raf.setPositionSync(len - tailLen);
    final tail = raf.readSync(tailLen);
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
    if (cdOffset + cdSize > len || cdSize > 64 << 20) return null;
    raf.setPositionSync(cdOffset);
    final cd = raf.readSync(cdSize);
    final c = ByteData.sublistView(cd);
    var p = 0;
    final wanted = utf8.encode(name);
    while (p + 46 <= cd.length && c.getUint32(p, Endian.little) == 0x02014b50) {
      final method = c.getUint16(p + 10, Endian.little);
      final compSize = c.getUint32(p + 20, Endian.little);
      final size = c.getUint32(p + 24, Endian.little);
      final nameLen = c.getUint16(p + 28, Endian.little);
      final extraLen = c.getUint16(p + 30, Endian.little);
      final commentLen = c.getUint16(p + 32, Endian.little);
      final localOffset = c.getUint32(p + 42, Endian.little);
      if (p + 46 + nameLen > cd.length) return null;
      if (_sameBytes(cd, p + 46, nameLen, wanted)) {
        if (size > _maxEntry || compSize > _maxEntry) return null;
        raf.setPositionSync(localOffset);
        final lh = raf.readSync(30);
        if (lh.length < 30) return null;
        final l = ByteData.sublistView(lh);
        if (l.getUint32(0, Endian.little) != 0x04034b50) return null;
        final skip = l.getUint16(26, Endian.little) + l.getUint16(28, Endian.little);
        raf.setPositionSync(localOffset + 30 + skip);
        final data = raf.readSync(compSize);
        if (data.length != compSize) return null;
        return switch (method) {
          0 => data,
          8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(data)),
          _ => null,
        };
      }
      p += 46 + nameLen + extraLen + commentLen;
    }
    return null;
  } on Object {
    // jar troncato, permessi, deflate rotto: semplicemente niente
    return null;
  } finally {
    raf?.closeSync();
  }
}

bool _sameBytes(Uint8List buf, int start, int len, List<int> want) {
  if (len != want.length) return false;
  for (var i = 0; i < len; i++) {
    if (buf[start + i] != want[i]) return false;
  }
  return true;
}
