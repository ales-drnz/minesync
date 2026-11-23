// Chunking definito dal contenuto (FastCDC con "normalized chunking") per i
// file grandi, soprattutto i region file di Minecraft: un salvataggio cambia
// pochi kB di un file da decine di MB, e con confini decisi dal contenuto
// solo i chunk toccati cambiano hash.
//
// I parametri e la gear table fanno parte del protocollo: cambiarli fa
// produrre chunk diversi a file uguali e annulla la deduplica.
import 'dart:typed_data';

/// Mai tagliare prima di 256 KiB.
const int chunkMin = 256 << 10;

/// Taglio medio atteso: 512 KiB (2^19).
const int chunkAvg = 512 << 10;

/// Taglio forzato a 2 MiB.
const int chunkMax = 2 << 20;

const int _avgBits = 19;

// Maschere con i bit in cima alla parola: il gear hash scorre a sinistra,
// quindi solo i bit alti dipendono da tutta la finestra (~64 byte). Prima
// della media si usa la maschera più esigente (bits+2), dopo la più
// permissiva (bits-2): le taglie si stringono attorno alla media.
const int _maskS = ((1 << (_avgBits + 2)) - 1) << (64 - (_avgBits + 2));
const int _maskL = ((1 << (_avgBits - 2)) - 1) << (64 - (_avgBits - 2));

/// 256 valori pseudo-casuali deterministici (splitmix64, seed fisso).
final Int64List gearTable = () {
  final t = Int64List(256);
  var x = 0x6d696e6573796e63; // "minesync" in ASCII: seed del protocollo 0.1
  for (var i = 0; i < 256; i++) {
    x += 0x9e3779b97f4a7c15;
    var z = x;
    z = (z ^ (z >>> 30)) * 0xbf58476d1ce4e5b9;
    z = (z ^ (z >>> 27)) * 0x94d049bb133111eb;
    t[i] = z ^ (z >>> 31);
  }
  return t;
}();

/// Stato del chunker su uno stream. Si alimenta a blocchi con [scan].
final class FastCdc {
  int _n = 0;
  int _gear = 0;

  /// Byte nel chunk corrente.
  int get pending => _n;

  /// Scorre [data] da [start] a [end] e restituisce l'indice (esclusivo)
  /// del primo taglio, o -1 se il chunk corrente non si chiude in questo
  /// intervallo. Dopo un taglio lo stato riparte da zero: si richiama da
  /// quell'indice.
  int scan(Uint8List data, int start, int end) {
    final g = gearTable;
    var n = _n;
    var gear = _gear;
    var i = start;
    // Il gear scorre a sinistra di un bit per byte: dopo 64 byte un byte non
    // conta più. Prima di chunkMin non si taglia, quindi si saltano i byte
    // fino a 64 prima di chunkMin senza cambiare il risultato.
    const warm = chunkMin - 64;
    if (n < warm) {
      final skip = warm - n < end - i ? warm - n : end - i;
      i += skip;
      n += skip;
    }
    for (; i < end; i++) {
      gear = (gear << 1) + g[data[i]];
      n++;
      if (n < chunkMin) continue;
      final mask = n > chunkAvg ? _maskL : _maskS;
      if ((gear & mask) == 0 || n >= chunkMax) {
        _n = 0;
        _gear = 0;
        return i + 1;
      }
    }
    _n = n;
    _gear = gear;
    return -1;
  }

  void reset() {
    _n = 0;
    _gear = 0;
  }
}

/// Confini dei chunk di [data] (indici di fine, esclusivi); comodo per i test
/// e per i dati in memoria.
List<int> chunkBoundaries(Uint8List data) {
  final c = FastCdc();
  final out = <int>[];
  var pos = 0;
  while (pos < data.length) {
    final cut = c.scan(data, pos, data.length);
    if (cut < 0) break;
    out.add(cut);
    pos = cut;
  }
  if (out.isEmpty || out.last != data.length) {
    if (data.isNotEmpty) out.add(data.length);
  }
  return out;
}
