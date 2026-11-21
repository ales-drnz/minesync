// Tar minimale (ustar + record PAX per nomi lunghi), scritto qui invece di
// usare package:archive per due motivi: estrazione in streaming con hash per
// file mentre si scrive, e controllo totale su cosa accettiamo (solo file
// regolari, cartelle e symlink; niente hardlink, device, fifo).
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Voce da scrivere nell'archivio.
class TarEntryIn {
  final String path;
  final int mode;
  final Uint8List? data; // null per symlink
  final String? linkTarget;
  TarEntryIn.file(this.path, this.data, {this.mode = 420}) : linkTarget = null;
  TarEntryIn.link(this.path, this.linkTarget)
      : data = null,
        mode = 511;
}

/// Costruisce l'archivio tar in memoria (lo usa solo il tool di firma).
Uint8List buildTar(List<TarEntryIn> entries) {
  final out = BytesBuilder(copy: false);
  for (final e in entries) {
    final isLink = e.linkTarget != null;
    final nameBytes = utf8.encode(e.path);
    final linkBytes = utf8.encode(e.linkTarget ?? '');
    if (nameBytes.length > 99 || linkBytes.length > 99) {
      // Header PAX con path/linkpath completi; il nome ustar è troncato.
      final recs = BytesBuilder();
      recs.add(_paxRecord('path', e.path));
      if (isLink) recs.add(_paxRecord('linkpath', e.linkTarget!));
      final body = recs.takeBytes();
      out.add(_header('PaxHeader', 420, body.length, 'x', ''));
      out.add(body);
      out.add(Uint8List(_pad(body.length)));
    }
    final size = isLink ? 0 : e.data!.length;
    out.add(_header(_trunc(e.path), e.mode, size, isLink ? '2' : '0',
        _trunc(e.linkTarget ?? '')));
    if (!isLink) {
      out.add(e.data!);
      out.add(Uint8List(_pad(size)));
    }
  }
  out.add(Uint8List(1024)); // due blocchi a zero = fine archivio
  return out.takeBytes();
}

String _trunc(String s) {
  final b = utf8.encode(s);
  return b.length <= 99 ? s : String.fromCharCodes(b.sublist(0, 99).map((c) => c & 0x7f));
}

Uint8List _paxRecord(String k, String v) {
  final payload = utf8.encode(' $k=$v\n');
  var len = payload.length;
  // La lunghezza include le proprie cifre.
  while ('$len'.length + payload.length != len) {
    len = '$len'.length + payload.length;
  }
  return Uint8List.fromList([...utf8.encode('$len'), ...payload]);
}

int _pad(int n) => (512 - n % 512) % 512;

Uint8List _header(String name, int mode, int size, String type, String link) {
  final h = Uint8List(512);
  void put(int off, int len, String s) {
    final b = utf8.encode(s);
    h.setRange(off, off + (b.length < len ? b.length : len), b);
  }

  String oct(int v, int width) => '${v.toRadixString(8).padLeft(width - 1, '0')}\x00';
  put(0, 100, name);
  put(100, 8, oct(mode, 8));
  put(108, 8, oct(0, 8));
  put(116, 8, oct(0, 8));
  put(124, 12, oct(size, 12));
  put(136, 12, oct(0, 12)); // mtime 0: archivi riproducibili
  put(156, 1, type);
  put(157, 100, link);
  put(257, 6, 'ustar\x00');
  put(263, 2, '00');
  for (var i = 148; i < 156; i++) {
    h[i] = 0x20;
  }
  final sum = h.fold<int>(0, (a, b) => a + b);
  put(148, 8, '${sum.toRadixString(8).padLeft(6, '0')}\x00 ');
  return h;
}

/// Tipo di voce letta.
enum TarType { file, dir, symlink }

/// Header di una voce letta; il contenuto si consuma con [TarReader.readData].
class TarHeader {
  final String path;
  final TarType type;
  final int mode;
  final int size;
  final String? linkTarget;
  TarHeader(this.path, this.type, this.mode, this.size, this.linkTarget);
}

class TarFormatException implements Exception {
  final String msg;
  TarFormatException(this.msg);
  @override
  String toString() => 'tar non valido: $msg';
}

/// Lettore tar in streaming sopra uno Stream di byte (già decompresso).
class TarReader {
  final StreamIterator<List<int>> _it;
  Uint8List _buf = Uint8List(0);
  int _pos = 0;
  int _pendingData = 0; // byte (dati + padding) della voce corrente non ancora letti

  TarReader(Stream<List<int>> input) : _it = StreamIterator(input);

  Future<bool> _fill() async {
    if (!await _it.moveNext()) return false;
    final c = _it.current;
    _buf = c is Uint8List ? c : Uint8List.fromList(c);
    _pos = 0;
    return true;
  }

  /// Legge esattamente [n] byte.
  Future<Uint8List> _read(int n) async {
    final out = Uint8List(n);
    var off = 0;
    while (off < n) {
      if (_pos >= _buf.length && !await _fill()) {
        throw TarFormatException('archivio troncato');
      }
      final k = (n - off) < (_buf.length - _pos) ? (n - off) : (_buf.length - _pos);
      out.setRange(off, off + k, _buf, _pos);
      off += k;
      _pos += k;
    }
    return out;
  }

  /// Passa al contenuto della voce corrente a pezzi, chiamando [onChunk].
  Future<void> readData(TarHeader h, FutureOr<void> Function(Uint8List) onChunk) async {
    var left = h.size;
    while (left > 0) {
      if (_pos >= _buf.length && !await _fill()) {
        throw TarFormatException('archivio troncato');
      }
      final k = left < (_buf.length - _pos) ? left : (_buf.length - _pos);
      await onChunk(Uint8List.sublistView(_buf, _pos, _pos + k));
      _pos += k;
      left -= k;
    }
    await _read(_pad(h.size));
    _pendingData = 0;
  }

  /// Prossima voce, o null a fine archivio. Salta i dati non letti.
  Future<TarHeader?> next() async {
    if (_pendingData > 0) {
      await _read(_pendingData);
      _pendingData = 0;
    }
    Map<String, String> pax = {};
    String? gnuLong;
    while (true) {
      final h = await _read(512);
      if (h.every((b) => b == 0)) return null;
      _checksum(h);
      final type = String.fromCharCode(h[156] == 0 ? 0x30 : h[156]);
      final size = _octal(h, 124, 12);
      if (size < 0 || size > (1 << 40)) throw TarFormatException('dimensione assurda');
      if (type == 'x' || type == 'g' || type == 'L') {
        if (size > 1 << 20) throw TarFormatException('header esteso troppo grande');
        final body = await _read(size);
        await _read(_pad(size));
        if (type == 'x') pax = _parsePax(body);
        if (type == 'L') gnuLong = utf8.decode(body).split('\x00').first;
        continue;
      }
      final prefix = _str(h, 345, 155);
      var name = pax['path'] ?? gnuLong ?? (prefix.isEmpty ? _str(h, 0, 100) : '$prefix/${_str(h, 0, 100)}');
      final link = pax['linkpath'] ?? _str(h, 157, 100);
      final mode = _octal(h, 100, 8);
      final TarType t;
      switch (type) {
        case '0':
        case '7':
          t = TarType.file;
        case '5':
          t = TarType.dir;
          if (name.endsWith('/')) name = name.substring(0, name.length - 1);
        case '2':
          t = TarType.symlink;
        default:
          throw TarFormatException('tipo di voce non ammesso: "$type" ($name)');
      }
      final hdr = TarHeader(name, t, mode, t == TarType.file ? size : 0, t == TarType.symlink ? link : null);
      _pendingData = t == TarType.file ? size + _pad(size) : 0;
      return hdr;
    }
  }

  Future<void> cancel() => _it.cancel();

  static void _checksum(Uint8List h) {
    final want = _octal(h, 148, 8);
    var sum = 0;
    for (var i = 0; i < 512; i++) {
      sum += (i >= 148 && i < 156) ? 0x20 : h[i];
    }
    if (sum != want) throw TarFormatException('checksum header errato');
  }

  static String _str(Uint8List h, int off, int len) {
    var end = off;
    while (end < off + len && h[end] != 0) {
      end++;
    }
    return utf8.decode(h.sublist(off, end), allowMalformed: false);
  }

  static int _octal(Uint8List h, int off, int len) {
    final s = _str(h, off, len).trim();
    if (s.isEmpty) return 0;
    final v = int.tryParse(s, radix: 8);
    if (v == null) throw TarFormatException('campo ottale non valido');
    return v;
  }

  static Map<String, String> _parsePax(Uint8List body) {
    final out = <String, String>{};
    var i = 0;
    while (i < body.length) {
      final sp = body.indexOf(0x20, i);
      if (sp < 0) break;
      final len = int.tryParse(ascii.decode(body.sublist(i, sp)));
      if (len == null || len <= 0 || i + len > body.length) throw TarFormatException('record PAX');
      final rec = utf8.decode(body.sublist(sp + 1, i + len - 1));
      final eq = rec.indexOf('=');
      if (eq > 0) out[rec.substring(0, eq)] = rec.substring(eq + 1);
      i += len;
    }
    return out;
  }
}
