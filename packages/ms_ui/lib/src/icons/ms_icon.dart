// Widget di icone, logo e illustrazioni: rettangoli pieni su pixel fisici
// interi, con una scala intera per cella a ogni dpr (niente pixel sfumati).
import 'package:flutter/widgets.dart';

import '../pixel/grid.dart';
import '../pixel/render.dart';
import '../theme.dart';
import 'icon_data.dart';
import 'icons.g.dart';

/// Physical pixels per cell for [cells] cells in a box of [box] physical
/// pixels: the largest integer that fits (at least 1).
int _cellPhys(int box, int cells) => box < cells ? 1 : box ~/ cells;

/// Side of the box in whole physical pixels.
int _boxPhys(PixelCanvas c, double size) => (c.g.d(size) * c.g.dpr).round();

/// A pixel icon from [MsIcons], drawn like the canvas' `svg.ms-ico`.
///
/// [size] is in design pixels (16, 24 or 32 in the canvas). Each icon cell is
/// a whole number of physical pixels, so the icon is crisp at every device
/// pixel ratio; when the box is not a multiple of the grid the icon is
/// centred in it (e.g. 24 at 150 %: cells of 4 px in a 36 px box).
///
/// Without [color] the icon takes the colour of the nearest [IconTheme],
/// otherwise of the surrounding [DefaultTextStyle] (the CSS `currentColor`).
class MsIcon extends StatelessWidget {
  const MsIcon(this.icon, {super.key, this.size, this.color, this.semanticLabel});

  final MsIconData icon;

  /// Side of the icon in design pixels. Without it the icon takes the size of
  /// the nearest [IconTheme] (the components set it, e.g. 32 in the play
  /// button), otherwise 16.
  final double? size;

  final Color? color;

  /// Label for screen readers; without it the icon is decorative and hidden
  /// from the semantics tree (the canvas' `aria-hidden`).
  final String? semanticLabel;

  /// The colour the icon is drawn with in [context] when [color] is null.
  static Color currentColor(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data.color ??
      DefaultTextStyle.of(context).style.color ??
      MsTheme.colorsOf(context).text;

  /// Side in design pixels in [context].
  static double sizeOf(BuildContext context, double? size) {
    if (size != null) return size;
    final logical = context.dependOnInheritedWidgetOfExactType<IconTheme>()?.data.size;
    if (logical == null) return 16;
    // IconTheme porta pixel logici: si torna ai pixel di design della griglia
    return (logical / PixelScope.of(context).unit * 2).roundToDouble();
  }

  @override
  Widget build(BuildContext context) {
    final ink = color ?? currentColor(context);
    final size = sizeOf(context, this.size);
    final box = PixelBox(
      width: size,
      height: size,
      repaintKey: (icon, ink),
      painter: (c, w, h) {
        final b = _boxPhys(c, size);
        final px = _cellPhys(b, icon.width);
        final off = (b - icon.width * px) ~/ 2;
        final r = icon.runs;
        for (var i = 0; i < r.length; i += 3) {
          c.rectPhys(off + r[i] * px, off + r[i + 1] * px, r[i + 2] * px, px, ink);
        }
      },
    );
    if (semanticLabel == null) return ExcludeSemantics(child: box);
    return Semantics(label: semanticLabel, image: true, child: box);
  }
}

/// Logo colours of [palette].
MsLogoPalette msLogoPaletteOf(MsPalette palette) => switch (palette) {
  MsPalette.prato => msLogoPrato,
  MsPalette.abisso => msLogoAbisso,
};

/// The MineSync logo, the "Sync block" (proposal A of the identity canvas).
///
/// [size] is in design pixels. The drawing is chosen by the physical size of
/// the box: the 16, 32 or 64 grid at the largest integer scale that fits,
/// centred with a transparent margin when it does not fill the box (see
/// [logoLayout]). The colours follow the palette of the current [MsTheme]
/// (or [palette]) and do not change between dark and light themes.
class MsLogo extends StatelessWidget {
  const MsLogo({super.key, this.size = 32, this.palette, this.semanticLabel = 'MineSync'});

  /// Side of the logo in design pixels.
  final double size;

  /// Palette of the colours; by default the one of the theme.
  final MsPalette? palette;

  /// Label for screen readers; null makes the logo decorative.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final pal = palette ?? MsTheme.of(context).palette;
    final colors = [for (final c in msLogoPaletteOf(pal).roles) Color(c)];
    final box = PixelBox(
      width: size,
      height: size,
      repaintKey: pal,
      painter: (c, w, h) {
        final l = logoLayout(msLogoArt, _boxPhys(c, size));
        _paintArt(c, l.art, l.scale, l.offset, colors);
      },
    );
    if (semanticLabel == null) return ExcludeSemantics(child: box);
    return Semantics(label: semanticLabel, image: true, child: box);
  }
}

/// An empty-state illustration from [MsArts], coloured with the theme's
/// `--ms-logo-*` tokens (the canvas' `svg.ms-empty__art.ms-logo`, 96 px).
class MsArt extends StatelessWidget {
  const MsArt(this.art, {super.key, this.size = 96, this.semanticLabel});

  final MsPixelArt art;

  /// Side in design pixels.
  final double size;

  /// Label for screen readers; without it the art is decorative.
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final t = MsTheme.colorsOf(context);
    final colors = [t.logoO, t.logoH, t.logoG, t.logoD, t.logoK, t.logoW];
    final box = PixelBox(
      width: size,
      height: size,
      repaintKey: (art, t),
      painter: (c, w, h) {
        final b = _boxPhys(c, size);
        final px = _cellPhys(b, art.width);
        _paintArt(c, art, px, (b - art.width * px) ~/ 2, colors);
      },
    );
    if (semanticLabel == null) return ExcludeSemantics(child: box);
    return Semantics(label: semanticLabel, image: true, child: box);
  }
}

void _paintArt(PixelCanvas c, MsPixelArt art, int px, int off, List<Color> colors) {
  final r = art.runs;
  for (var i = 0; i < r.length; i += 4) {
    c.rectPhys(off + r[i] * px, off + r[i + 1] * px, r[i + 2] * px, px, colors[r[i + 3]]);
  }
}
