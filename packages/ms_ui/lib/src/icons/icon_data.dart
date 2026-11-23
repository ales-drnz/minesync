// Dati di icone, logo e illustrazioni pixel: solo Dart puro (niente Flutter),
// così li usa anche tool/export_icon.dart con `dart run`.
//
// Le bitmap sono memorizzate come "corse" orizzontali di celle piene, già
// calcolate dal generatore (tool/gen_icons.dart) a partire da icons/icons.json.
library;

/// A single-colour pixel icon: a bitmap of [width] × [height] cells drawn in
/// the current colour (the canvas' `fill: currentColor`).
final class MsIconData {
  const MsIconData(this.name, this.width, this.height, this.runs);

  /// Name in the design canvas (e.g. `play`).
  final String name;
  final int width;
  final int height;

  /// Filled horizontal runs, flattened as `x, y, length` triples.
  final List<int> runs;

  /// True if cell ([x], [y]) is filled.
  bool filled(int x, int y) {
    for (var i = 0; i < runs.length; i += 3) {
      if (runs[i + 1] == y && x >= runs[i] && x < runs[i] + runs[i + 2]) return true;
    }
    return false;
  }

  @override
  String toString() => 'MsIconData($name)';
}

/// A multi-colour pixel bitmap: each run carries a colour role, an index into
/// a role list that depends on the art (logo palette or `--ms-logo-*` tokens).
final class MsPixelArt {
  const MsPixelArt(this.width, this.height, this.runs);

  final int width;
  final int height;

  /// Filled horizontal runs, flattened as `x, y, length, role` quadruples.
  final List<int> runs;

  /// Role of cell ([x], [y]), or -1 if transparent.
  int roleAt(int x, int y) {
    for (var i = 0; i < runs.length; i += 4) {
      if (runs[i + 1] == y && x >= runs[i] && x < runs[i] + runs[i + 2]) return runs[i + 3];
    }
    return -1;
  }
}

/// Colours of the "Sync block" logo for one palette, as ARGB integers.
///
/// Roles follow the canvas (`Identity.dc.html`, "Palette usata"): outline,
/// light accent, accent, dark accent, side, engraving.
final class MsLogoPalette {
  const MsLogoPalette({
    required this.outline,
    required this.light,
    required this.accent,
    required this.dark,
    required this.side,
    required this.engrave,
  });

  final int outline;
  final int light;
  final int accent;
  final int dark;
  final int side;
  final int engrave;

  /// Colours indexed by the role stored in the logo runs.
  List<int> get roles => [outline, light, accent, dark, side, engrave];
}

/// The three hand-drawn designs of the logo, one per grid size.
final class MsLogoArt {
  const MsLogoArt({required this.grid16, required this.grid32, required this.grid64});

  final MsPixelArt grid16;
  final MsPixelArt grid32;
  final MsPixelArt grid64;

  /// Designs from the largest to the smallest grid.
  List<MsPixelArt> get designs => [grid64, grid32, grid16];
}

/// How the logo fills a square box of physical pixels.
typedef MsLogoLayout = ({MsPixelArt art, int scale, int offset});

/// Picks design and integer scale for a square box of [box] physical pixels.
///
/// The drawn logo (grid × scale) is the largest that fits in [content]
/// pixels (default: the whole box); with equal sizes the larger grid wins,
/// so 48 is the 16 grid ×3, 64 the 64 grid ×1 and 96 the 32 grid ×3, as in
/// the canvas. It is centred, leaving a transparent margin when it does not
/// fill the box (24 → 16 + 4 + 4). Below 16 pixels the 16 grid is used at ×1.
MsLogoLayout logoLayout(MsLogoArt logo, int box, {int? content}) {
  final limit = content ?? box;
  var best = logo.grid16;
  var bestScale = 1;
  var bestSize = 0;
  for (final art in logo.designs) {
    final k = limit ~/ art.width;
    if (k >= 1 && art.width * k > bestSize) {
      best = art;
      bestScale = k;
      bestSize = art.width * k;
    }
  }
  return (art: best, scale: bestScale, offset: (box - best.width * bestScale) ~/ 2);
}
