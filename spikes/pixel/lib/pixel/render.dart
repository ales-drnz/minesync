// Primitive di disegno pixel: tutti i rettangoli sono espressi in px di design
// e finiscono su confini di pixel fisici, perché l'origine viene allineata al
// pixel fisico (pixelSnapDelta) e le misure sono multipli dell'unità.
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'grid.dart';

/// Tela con coordinate in px di design a partire da un'origine già allineata.
class PixelCanvas {
  PixelCanvas(this.canvas, this.g, this.origin);

  final Canvas canvas;
  final PixelGrid g;
  final Offset origin;
  final Paint _paint = Paint()..isAntiAlias = true;

  /// Nuova tela spostata di [dx]/[dy] pixel FISICI interi.
  PixelCanvas shiftPhys(int dx, int dy) =>
      PixelCanvas(canvas, g, origin + Offset(g.phys(dx), g.phys(dy)));

  /// Rettangolo pieno in px di design.
  void rect(num x, num y, num w, num h, Color color) {
    if (w <= 0 || h <= 0) return;
    _paint.color = color;
    canvas.drawRect(
      Rect.fromLTWH(origin.dx + g.d(x), origin.dy + g.d(y), g.d(w), g.d(h)),
      _paint,
    );
  }

  /// Rettangolo pieno in pixel FISICI interi (per icone con scala propria).
  void rectPhys(int x, int y, int w, int h, Color color) {
    if (w <= 0 || h <= 0) return;
    _paint.color = color;
    canvas.drawRect(
      Rect.fromLTWH(origin.dx + g.phys(x), origin.dy + g.phys(y), g.phys(w),
          g.phys(h)),
      _paint,
    );
  }

  /// Contorno "pixel" da 2 px con angoli smussati (come --ms-ring):
  /// quattro lati senza i quadratini d'angolo.
  void ring(num x, num y, num w, num h, Color color, {num t = 2}) {
    rect(x - t, y, t, h, color);
    rect(x + w, y, t, h, color);
    rect(x, y - t, w, t, color);
    rect(x, y + h, w, t, color);
  }

  /// Contorno quadrato pieno (outline CSS) attorno al rettangolo dato.
  void outline(num x, num y, num w, num h, Color color, {num t = 2}) {
    rect(x - t, y - t, w + 2 * t, t, color);
    rect(x - t, y + h, w + 2 * t, t, color);
    rect(x - t, y, t, h, color);
    rect(x + w, y, t, h, color);
  }

  /// Rilievo (--ms-bevel-out / -in): luce su alto+sinistra sopra a
  /// ombra su destra+basso; [inverted] scambia i colori.
  void bevel(num w, num h, Color light, Color shadow, {bool inverted = false}) {
    final a = inverted ? shadow : light; // alto + sinistra (sopra)
    final b = inverted ? light : shadow; // destra + basso
    rect(w - 2, 0, 2, h, b);
    rect(0, h - 2, w, 2, b);
    rect(0, 0, w, 2, a);
    rect(0, 0, 2, h, a);
  }

  void image(ui.Image img, num x, num y, num w, num h) {
    final dst = Rect.fromLTWH(origin.dx + g.d(x), origin.dy + g.d(y), g.d(w),
        g.d(h));
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      dst,
      Paint()..filterQuality = FilterQuality.none,
    );
  }
}

typedef PixelPainter = void Function(PixelCanvas c, double w, double h);

/// Riquadro pixel con un figlio: dimensioni arrotondate per eccesso all'unità,
/// sfondo/bordi disegnati da [painter] (in px di design, sul box interno),
/// zona esterna [outset] riservata a contorni e lati che escono dal box.
class PixelFrame extends SingleChildRenderObjectWidget {
  const PixelFrame({
    super.key,
    required this.painter,
    this.padding = EdgeInsets.zero,
    this.outset = EdgeInsets.zero,
    this.minWidth = 0,
    this.minHeight = 0,
    this.centerX = false,
    this.centerY = false,
    this.childShiftPhys = 0,
    this.repaintKey,
    super.child,
  });

  final PixelPainter painter;
  final EdgeInsets padding; // px di design
  final EdgeInsets outset; // px di design
  final double minWidth; // px di design (box interno)
  final double minHeight;
  final bool centerX;
  final bool centerY;
  final int childShiftPhys; // spostamento verticale del figlio, pixel fisici
  final Object? repaintKey; // cambia => ridisegna

  @override
  RenderPixelFrame createRenderObject(BuildContext context) => RenderPixelFrame(
        grid: PixelScope.of(context),
        painter: painter,
        padding: padding,
        outset: outset,
        minWidth: minWidth,
        minHeight: minHeight,
        centerX: centerX,
        centerY: centerY,
        childShiftPhys: childShiftPhys,
        repaintKey: repaintKey,
      );

  @override
  void updateRenderObject(BuildContext context, RenderPixelFrame r) {
    r
      ..grid = PixelScope.of(context)
      ..painter = painter
      ..padding = padding
      ..outset = outset
      ..minWidth = minWidth
      ..minHeight = minHeight
      ..centerX = centerX
      ..centerY = centerY
      ..childShiftPhys = childShiftPhys
      ..repaintKey = repaintKey;
  }
}

class RenderPixelFrame extends RenderShiftedBox {
  RenderPixelFrame({
    required PixelGrid grid,
    required this.painter,
    required EdgeInsets padding,
    required EdgeInsets outset,
    required double minWidth,
    required double minHeight,
    required bool centerX,
    required bool centerY,
    required int childShiftPhys,
    Object? repaintKey,
  })  : _grid = grid,
        _padding = padding,
        _outset = outset,
        _minWidth = minWidth,
        _minHeight = minHeight,
        _centerX = centerX,
        _centerY = centerY,
        _childShiftPhys = childShiftPhys,
        _repaintKey = repaintKey,
        super(null);

  PixelGrid _grid;
  set grid(PixelGrid v) {
    if (v == _grid) return;
    _grid = v;
    markNeedsLayout();
  }

  // Il painter è una closure: la si sostituisce sempre, il ridisegno è
  // pilotato da repaintKey.
  PixelPainter painter;

  EdgeInsets _padding;
  set padding(EdgeInsets v) {
    if (v == _padding) return;
    _padding = v;
    markNeedsLayout();
  }

  EdgeInsets _outset;
  set outset(EdgeInsets v) {
    if (v == _outset) return;
    _outset = v;
    markNeedsLayout();
  }

  double _minWidth;
  set minWidth(double v) {
    if (v == _minWidth) return;
    _minWidth = v;
    markNeedsLayout();
  }

  double _minHeight;
  set minHeight(double v) {
    if (v == _minHeight) return;
    _minHeight = v;
    markNeedsLayout();
  }

  bool _centerX;
  set centerX(bool v) {
    if (v == _centerX) return;
    _centerX = v;
    markNeedsLayout();
  }

  bool _centerY;
  set centerY(bool v) {
    if (v == _centerY) return;
    _centerY = v;
    markNeedsLayout();
  }

  int _childShiftPhys;
  set childShiftPhys(int v) {
    if (v == _childShiftPhys) return;
    _childShiftPhys = v;
    markNeedsPaint();
  }

  Object? _repaintKey;
  set repaintKey(Object? v) {
    if (v == _repaintKey) return;
    _repaintKey = v;
    markNeedsPaint();
  }

  Size _box = Size.zero; // box interno, logico

  EdgeInsets _l(EdgeInsets e) =>
      EdgeInsets.fromLTRB(_grid.d(e.left), _grid.d(e.top), _grid.d(e.right),
          _grid.d(e.bottom));

  @override
  void performLayout() {
    final g = _grid;
    final pad = _l(_padding);
    final out = _l(_outset);
    final inner = constraints.deflate(out).deflate(pad).loosen();
    Size cs = Size.zero;
    if (child != null) {
      child!.layout(inner, parentUsesSize: true);
      cs = child!.size;
    }
    var bw = g.ceilToUnit(cs.width + pad.horizontal);
    var bh = g.ceilToUnit(cs.height + pad.vertical);
    if (bw < g.d(_minWidth)) bw = g.d(_minWidth);
    if (bh < g.d(_minHeight)) bh = g.d(_minHeight);
    // Se il genitore impone una larghezza (es. stretch), la si rispetta
    // arrotondata per difetto all'unità.
    final maxW = constraints.maxWidth - out.horizontal;
    if (constraints.hasTightWidth && maxW.isFinite) {
      bw = (maxW / g.unit + 1e-6).floorToDouble() * g.unit;
    }
    _box = Size(bw, bh);
    size = constraints.constrain(
        Size(bw + out.horizontal, bh + out.vertical));
    if (child != null) {
      var dx = out.left + pad.left;
      var dy = out.top + pad.top;
      if (_centerX) dx = out.left + g.roundToUnit((bw - cs.width) / 2);
      if (_centerY) dy = out.top + g.roundToUnit((bh - cs.height) / 2);
      (child!.parentData! as BoxParentData).offset = Offset(dx, dy);
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = _grid;
    final base = offset + pixelSnapDelta(this, g);
    final out = _l(_outset);
    final c = PixelCanvas(context.canvas, g, base + out.topLeft);
    painter(c, _box.width / g.unit * 2, _box.height / g.unit * 2);
    if (child != null) {
      final pd = child!.parentData! as BoxParentData;
      context.paintChild(
          child!, base + pd.offset + Offset(0, g.phys(_childShiftPhys)));
    }
  }

  @override
  bool hitTestSelf(Offset position) => size.contains(position);
}

/// Foglia pixel di dimensione fissa in px di design.
class PixelBox extends LeafRenderObjectWidget {
  const PixelBox({
    super.key,
    required this.width,
    required this.height,
    required this.painter,
    this.repaintKey,
  });

  final double width;
  final double height;
  final PixelPainter painter;
  final Object? repaintKey;

  @override
  RenderPixelBox createRenderObject(BuildContext context) => RenderPixelBox(
      PixelScope.of(context), width, height, painter, repaintKey);

  @override
  void updateRenderObject(BuildContext context, RenderPixelBox r) {
    r.update(PixelScope.of(context), width, height, painter, repaintKey);
  }
}

class RenderPixelBox extends RenderBox {
  RenderPixelBox(this._g, this._w, this._h, this._painter, this._key);

  PixelGrid _g;
  double _w;
  double _h;
  PixelPainter _painter;
  Object? _key;

  void update(PixelGrid g, double w, double h, PixelPainter p, Object? key) {
    final relayout = g != _g || w != _w || h != _h;
    final repaint = key != _key;
    _g = g;
    _w = w;
    _h = h;
    _painter = p;
    _key = key;
    if (relayout) {
      markNeedsLayout();
    } else if (repaint) {
      markNeedsPaint();
    }
  }

  @override
  void performLayout() {
    size = constraints.constrain(Size(_g.d(_w), _g.d(_h)));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final c = PixelCanvas(
        context.canvas, _g, offset + pixelSnapDelta(this, _g));
    _painter(c, _w, _h);
  }
}

/// Spazio vuoto in px di design.
class PixelGap extends StatelessWidget {
  const PixelGap(this.w, [this.h, Key? key]) : super(key: key);
  final double w;
  final double? h;
  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return SizedBox(width: g.d(w), height: g.d(h ?? w));
  }
}
