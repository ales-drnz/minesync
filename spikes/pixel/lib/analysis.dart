// Analisi dei pixel (puro Dart, nessun dart:ui): usata dai test e da
// tool/analyze_goldens.dart sui PNG golden.
import 'dart:typed_data';

import 'ms/palette_hex.dart';

/// Immagine RGBA non premoltiplicata, 8 bit per canale.
class Px {
  Px(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;

  int at(int x, int y) {
    final i = (y * width + x) * 4;
    return (rgba[i + 3] << 24) | (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2];
  }
}

String hex(int argb) => '#${(argb & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0')}';

/// Colori ammessi nelle immagini di sola geometria: tutti i token pieni più le
/// composizioni precalcolate (ombra, frangia d'erba del GIOCA).
Set<int> geometryPalette() {
  // (accentHover coincide con accentHi nella palette prato: lista -> set)
  final s = <int>{}..addAll([
    0x00000000, // fuori dal disegno (trasparente)
    MsHex.bg, MsHex.panel, MsHex.panelHi, MsHex.inset, MsHex.overlay, MsHex.text,
    MsHex.text2, MsHex.pxLight, MsHex.pxShadow, MsHex.pxOutline, MsHex.accent,
    MsHex.accentHi, MsHex.accentLo, MsHex.accentHover, MsHex.onAccent, MsHex.ok,
    MsHex.warn, MsHex.err, MsHex.info, MsHex.focus, MsHex.conBg, MsHex.drop,
  ]);
  for (final face in [MsHex.accent, MsHex.accentHover]) {
    s.add(blendHex(MsHex.accentHi, face, .9));
    s.add(blendHex(MsHex.accentHi, face, .5));
  }
  return s;
}

class PurityResult {
  PurityResult(this.total, this.bad, this.samples, this.badColors);
  final int total;
  final int bad;
  final List<String> samples; // primi pixel fuori palette
  final Map<int, int> badColors;
  bool get ok => bad == 0;
}

/// Tolleranza zero: ogni pixel deve avere esattamente un colore della palette.
PurityResult checkPurity(Px img, Set<int> palette) {
  var bad = 0;
  final samples = <String>[];
  final colors = <int, int>{};
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final c = img.at(x, y);
      if (!palette.contains(c)) {
        bad++;
        colors[c] = (colors[c] ?? 0) + 1;
        if (samples.length < 8) samples.add('($x,$y)=${hex(c)}');
      }
    }
  }
  return PurityResult(img.width * img.height, bad, samples, colors);
}

/// Lunghezze delle sequenze orizzontali e verticali di [color] che NON sono
/// multipli di [unitPx]: un bordo da 2 px di design deve essere esattamente
/// unitPx pixel fisici.
({int runs, int bad, Map<int, int> lengths}) checkRuns(Px img, int color, int unitPx) {
  var runs = 0, bad = 0;
  final lengths = <int, int>{};
  void close(int n) {
    if (n == 0) return;
    runs++;
    lengths[n] = (lengths[n] ?? 0) + 1;
    if (n % unitPx != 0) bad++;
  }

  for (var y = 0; y < img.height; y++) {
    var n = 0;
    for (var x = 0; x < img.width; x++) {
      if (img.at(x, y) == color) {
        n++;
      } else {
        close(n);
        n = 0;
      }
    }
    close(n);
  }
  for (var x = 0; x < img.width; x++) {
    var n = 0;
    for (var y = 0; y < img.height; y++) {
      if (img.at(x, y) == color) {
        n++;
      } else {
        close(n);
        n = 0;
      }
    }
    close(n);
  }
  return (runs: runs, bad: bad, lengths: lengths);
}

class BandStats {
  BandStats(this.y0, this.y1, this.ink, this.pure, this.partial, this.mid);
  final int y0, y1;
  final int ink; // pixel diversi dallo sfondo
  final int pure; // esattamente il colore del testo
  final int partial; // colore intermedio (antialiasing)
  final int mid; // intermedi con copertura stimata 25..75%
  double get aaRatio => ink == 0 ? 0 : partial / ink;
  double get midRatio => ink == 0 ? 0 : mid / ink;
}

/// Divide l'immagine in bande orizzontali separate da righe di solo sfondo e
/// misura quanta antialiasing c'è nel testo di ciascuna.
List<BandStats> textBands(Px img, int bg, int fg) {
  final bands = <BandStats>[];
  int? start;
  var ink = 0, pure = 0, partial = 0, mid = 0;
  final br = (bg >> 16) & 0xFF, bgG = (bg >> 8) & 0xFF, bb = bg & 0xFF;
  final fr = (fg >> 16) & 0xFF, fgG = (fg >> 8) & 0xFF, fb = fg & 0xFF;
  final dr = fr - br, dg = fgG - bgG, db = fb - bb;
  final dd = (dr * dr + dg * dg + db * db).toDouble();
  for (var y = 0; y <= img.height; y++) {
    var rowInk = 0;
    if (y < img.height) {
      for (var x = 0; x < img.width; x++) {
        final c = img.at(x, y);
        if (c == bg || (c >> 24) == 0) continue;
        rowInk++;
        if (c == fg) {
          pure++;
        } else {
          partial++;
          final t = (((c >> 16) & 0xFF) - br) * dr + (((c >> 8) & 0xFF) - bgG) * dg + ((c & 0xFF) - bb) * db;
          final cov = t / dd;
          if (cov > .25 && cov < .75) mid++;
        }
      }
    }
    ink += rowInk;
    if (rowInk > 0) {
      start ??= y;
    } else if (start != null) {
      bands.add(BandStats(start, y, ink, pure, partial, mid));
      start = null;
      ink = pure = partial = mid = 0;
    }
  }
  return bands;
}
