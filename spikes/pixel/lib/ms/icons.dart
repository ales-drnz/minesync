// Icone 8x8 copiate dai tracciati di Components.dc.html (sezione "Icone pixel").
// Ogni icona è una lista di rettangoli [x, y, w, h] nella griglia 8x8.
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../pixel/grid.dart';
import '../pixel/render.dart';

typedef IconRects = List<List<int>>;

abstract final class MsIcons {
  static const play = [[2, 0, 1, 1], [2, 1, 2, 1], [2, 2, 3, 1], [2, 3, 4, 1], [2, 4, 4, 1], [2, 5, 3, 1], [2, 6, 2, 1], [2, 7, 1, 1]];
  static const lock = [[2, 0, 4, 1], [1, 1, 1, 1], [6, 1, 1, 1], [1, 2, 1, 1], [6, 2, 1, 1], [0, 3, 8, 1], [0, 4, 3, 1], [5, 4, 3, 1], [0, 5, 3, 1], [5, 5, 3, 1], [0, 6, 8, 1], [0, 7, 8, 1]];
  static const gear = [[3, 0, 2, 1], [1, 1, 1, 1], [3, 1, 2, 1], [6, 1, 1, 1], [2, 2, 4, 1], [0, 3, 3, 1], [5, 3, 3, 1], [0, 4, 3, 1], [5, 4, 3, 1], [2, 5, 4, 1], [1, 6, 1, 1], [3, 6, 2, 1], [6, 6, 1, 1], [3, 7, 2, 1]];
  static const folder = [[0, 1, 3, 1], [0, 2, 1, 1], [3, 2, 4, 1], [0, 3, 8, 1], [0, 4, 1, 1], [7, 4, 1, 1], [0, 5, 1, 1], [7, 5, 1, 1], [0, 6, 8, 1]];
  static const warn = [[3, 0, 2, 1], [3, 1, 2, 1], [2, 2, 1, 1], [5, 2, 1, 1], [2, 3, 1, 1], [5, 3, 1, 1], [1, 4, 1, 1], [3, 4, 2, 1], [6, 4, 1, 1], [1, 5, 1, 1], [6, 5, 1, 1], [0, 6, 1, 1], [3, 6, 2, 1], [7, 6, 1, 1], [0, 7, 8, 1]];
  static const check = [[6, 1, 2, 1], [5, 2, 2, 1], [0, 3, 1, 1], [4, 3, 2, 1], [0, 4, 2, 1], [3, 4, 2, 1], [1, 5, 3, 1], [2, 6, 1, 1]];
  static const globe = [[2, 0, 4, 1], [1, 1, 1, 1], [3, 1, 2, 1], [6, 1, 1, 1], [0, 2, 1, 1], [3, 2, 2, 1], [7, 2, 1, 1], [0, 3, 8, 1], [0, 4, 1, 1], [3, 4, 2, 1], [7, 4, 1, 1], [0, 5, 1, 1], [3, 5, 2, 1], [7, 5, 1, 1], [1, 6, 1, 1], [3, 6, 2, 1], [6, 6, 1, 1], [2, 7, 4, 1]];
  static const terminal = [[0, 0, 8, 1], [0, 1, 1, 1], [7, 1, 1, 1], [0, 2, 1, 1], [2, 2, 1, 1], [7, 2, 1, 1], [0, 3, 1, 1], [3, 3, 1, 1], [7, 3, 1, 1], [0, 4, 1, 1], [2, 4, 1, 1], [5, 4, 1, 1], [7, 4, 1, 1], [0, 5, 1, 1], [7, 5, 1, 1], [0, 6, 8, 1]];

  static const all = <String, IconRects>{
    'play': play, 'lock': lock, 'gear': gear, 'folder': folder,
    'warn': warn, 'check': check, 'globe': globe, 'terminal': terminal,
  };

  /// Bitmap RGBA 8x8 dell'icona (per la variante raster).
  static Future<ui.Image> toImage(IconRects rects, Color color) {
    final px = Uint8List(8 * 8 * 4);
    final argb = color.toARGB32();
    for (final r in rects) {
      for (var y = r[1]; y < r[1] + r[3]; y++) {
        for (var x = r[0]; x < r[0] + r[2]; x++) {
          final i = (y * 8 + x) * 4;
          px[i] = (argb >> 16) & 0xFF;
          px[i + 1] = (argb >> 8) & 0xFF;
          px[i + 2] = argb & 0xFF;
          px[i + 3] = 0xFF;
        }
      }
    }
    final c = Completer<ui.Image>();
    ui.decodeImageFromPixels(px, 8, 8, ui.PixelFormat.rgba8888, c.complete);
    return c.future;
  }
}

/// Pixel fisici per pixel d'icona: la dimensione nominale [size] (px di design)
/// viene arrotondata a un intero di pixel fisici per pixel d'icona.
int iconPixelPhys(PixelGrid g, double size) {
  final v = (size / 8 / 2 * g.unitPx).round();
  return v < 1 ? 1 : v;
}

/// Icona vettoriale: rettangoli pieni su griglia fisica intera, centrata nel
/// suo box (anch'esso intero).
class PixelIcon extends StatelessWidget {
  const PixelIcon(this.rects, {super.key, this.size = 16, required this.color});
  final IconRects rects;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return PixelBox(
      width: size,
      height: size,
      repaintKey: (rects, color),
      painter: (c, w, h) {
        final g = c.g;
        final p = iconPixelPhys(g, size);
        final boxPhys = (g.d(size) * g.dpr).round();
        final off = (boxPhys - 8 * p) ~/ 2;
        for (final r in rects) {
          c.rectPhys(off + r[0] * p, off + r[1] * p, r[2] * p, r[3] * p, color);
        }
      },
    );
  }
}

/// Icona raster: bitmap 8x8 scalata con FilterQuality.none a un multiplo
/// intero di pixel fisici.
class PixelImageIcon extends StatelessWidget {
  const PixelImageIcon(this.image, {super.key, this.size = 16});
  final ui.Image image;
  final double size;

  @override
  Widget build(BuildContext context) {
    return PixelBox(
      width: size,
      height: size,
      repaintKey: image,
      painter: (c, w, h) {
        final g = c.g;
        final p = iconPixelPhys(g, size);
        final boxPhys = (g.d(size) * g.dpr).round();
        final off = (boxPhys - 8 * p) ~/ 2;
        final o = c.origin + Offset(g.phys(off), g.phys(off));
        c.canvas.drawImageRect(
          image,
          const Rect.fromLTWH(0, 0, 8, 8),
          Rect.fromLTWH(o.dx, o.dy, g.phys(8 * p), g.phys(8 * p)),
          Paint()..filterQuality = FilterQuality.none,
        );
      },
    );
  }
}
