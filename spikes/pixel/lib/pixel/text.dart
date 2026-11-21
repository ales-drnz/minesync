// Testo pixel: dimensione del font in px di design convertita con la stessa
// unità della griglia (quindi Silkscreen 16/24/32 = 2/3/4 pixel di font per
// unità... moltiplicati per unitPx), origine allineata al pixel fisico e
// linea di base spostata sul pixel fisico intero più vicino.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'grid.dart';

enum PixelFont {
  pixelify,

  /// Silkscreen con coordinate riallineate alla griglia (tool/snap_silkscreen.py).
  silkscreen,

  /// Silkscreen originale di Google Fonts (solo per confronto).
  silkscreenOrig,
  mono,
}

@immutable
class PixelTextStyle {
  const PixelTextStyle({
    required this.font,
    required this.size,
    required this.lineHeight,
    required this.color,
    this.weight = 400,
    this.uppercase = false,
  });

  final PixelFont font;
  final double size; // px di design
  final double lineHeight; // px di design
  final Color color;
  final int weight;
  final bool uppercase;


  /// Dimensione del font in pixel logici. Per Silkscreen (griglia 8 px/em)
  /// il pixel del font viene arrotondato a un intero di pixel fisici, come
  /// le icone: 24 px a unitPx 3 diventerebbe 4,5 pixel fisici per pixel.
  bool get _isSilk => font == PixelFont.silkscreen || font == PixelFont.silkscreenOrig;

  double fontSize(PixelGrid g) {
    if (!_isSilk) return g.d(size);
    var p = (size / 8 / 2 * g.unitPx).round();
    if (p < 1) p = 1;
    return g.phys(8 * p);
  }

  PixelTextStyle copyWith({Color? color, int? weight, double? size, double? lineHeight}) =>
      PixelTextStyle(
        font: font,
        size: size ?? this.size,
        lineHeight: lineHeight ?? this.lineHeight,
        color: color ?? this.color,
        weight: weight ?? this.weight,
        uppercase: uppercase,
      );

  TextStyle toTextStyle(PixelGrid g) {
    final family = switch (font) {
      PixelFont.pixelify => 'PixelifySans',
      PixelFont.silkscreen => 'SilkscreenGrid',
      PixelFont.silkscreenOrig => 'Silkscreen',
      PixelFont.mono => 'JetBrainsMono',
    };
    final variable = !_isSilk;
    final fs = fontSize(g);
    return TextStyle(
      fontFamily: family,
      fontSize: fs,
      height: g.d(lineHeight) / fs,
      leadingDistribution: TextLeadingDistribution.even,
      color: color,
      fontWeight: FontWeight.values[((weight ~/ 100) - 1).clamp(0, 8)],
      fontVariations: variable ? [ui.FontVariation('wght', weight.toDouble())] : null,
    );
  }

  @override
  bool operator ==(Object o) =>
      o is PixelTextStyle &&
      o.font == font &&
      o.size == size &&
      o.lineHeight == lineHeight &&
      o.color == color &&
      o.weight == weight &&
      o.uppercase == uppercase;

  @override
  int get hashCode => Object.hash(font, size, lineHeight, color, weight, uppercase);
}

class PixelText extends LeafRenderObjectWidget {
  const PixelText(this.text, {super.key, required this.style, this.snapBaseline = true});

  final String text;
  final PixelTextStyle style;

  /// Se falso il testo viene disegnato senza correzione della linea di base
  /// (serve solo per il confronto nei golden).
  final bool snapBaseline;

  @override
  RenderPixelText createRenderObject(BuildContext context) =>
      RenderPixelText(PixelScope.of(context), text, style, snapBaseline);

  @override
  void updateRenderObject(BuildContext context, RenderPixelText r) =>
      r.update(PixelScope.of(context), text, style, snapBaseline);
}

class RenderPixelText extends RenderBox {
  RenderPixelText(this._g, this._text, this._style, this._snap);

  PixelGrid _g;
  String _text;
  PixelTextStyle _style;
  bool _snap;
  TextPainter? _tp;

  void update(PixelGrid g, String text, PixelTextStyle style, bool snap) {
    if (g == _g && text == _text && style == _style && snap == _snap) return;
    _g = g;
    _text = text;
    _style = style;
    _snap = snap;
    _tp?.dispose();
    _tp = null;
    markNeedsLayout();
  }

  TextPainter get _painter => _tp ??= TextPainter(
        text: TextSpan(
            text: _style.uppercase ? _text.toUpperCase() : _text,
            style: _style.toTextStyle(_g)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
        ellipsis: '…',
      );

  @override
  void performLayout() {
    final tp = _painter..layout(maxWidth: constraints.maxWidth);
    final w = constraints.hasTightWidth
        ? constraints.maxWidth
        : _g.ceilToUnit(tp.width).clamp(0.0, constraints.maxWidth);
    size = constraints.constrain(Size(w, _g.d(_style.lineHeight)));
  }

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) {
    final tp = _painter..layout(maxWidth: constraints.maxWidth);
    return (size.height - tp.height) / 2 +
        tp.computeDistanceToActualBaseline(baseline);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = _g;
    final tp = _painter;
    final base = offset + pixelSnapDelta(this, g);
    var dy = (size.height - tp.height) / 2;
    if (_snap) {
      final b = (dy + tp.computeDistanceToActualBaseline(TextBaseline.alphabetic)) * g.dpr;
      dy += (b.roundToDouble() - b) / g.dpr;
    }
    tp.paint(context.canvas, base + Offset(0, dy));
  }

  @override
  void dispose() {
    _tp?.dispose();
    super.dispose();
  }
}
