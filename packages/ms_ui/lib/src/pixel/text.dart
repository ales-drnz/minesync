// Testo del design system: dimensione del font in px di design convertita
// con la stessa unità della griglia, origine allineata al pixel fisico e
// linea di base spostata sul pixel fisico intero più vicino. Il testo è
// vettoriale (Atkinson Hyperlegible, JetBrains Mono): l'unica cosa con
// antialiasing in un'interfaccia fatta di rettangoli.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'grid.dart';

/// Famiglie di caratteri del design system (OFL 1.1, in assets/fonts).
enum PixelFont {
  /// Atkinson Hyperlegible (regular e bold): titoli, testo, etichette.
  sans,

  /// JetBrains Mono: codice, percorsi, console (variabile).
  mono,
}

/// Solo per i test: non disegna il testo (né [PixelText] né [MsText] su più
/// righe), per i golden che controllano la sola geometria a pixel pieni.
bool debugHideText = false;

/// [s] con l'iniziale maiuscola (il resto com'è).
String msSentenceCase(String s) {
  if (s.isEmpty) return s;
  final first = String.fromCharCode(s.runes.first);
  return first.toUpperCase() + s.substring(first.length);
}

@immutable
class PixelTextStyle {
  const PixelTextStyle({
    required this.font,
    required this.size,
    required this.lineHeight,
    required this.color,
    this.weight = 400,
  });

  final PixelFont font;
  final double size; // px di design
  final double lineHeight; // px di design
  final Color color;
  final int weight;

  /// Dimensione del font in pixel logici.
  double fontSize(PixelGrid g) => g.d(size);

  PixelTextStyle copyWith({Color? color, int? weight, double? size, double? lineHeight}) =>
      PixelTextStyle(
        font: font,
        size: size ?? this.size,
        lineHeight: lineHeight ?? this.lineHeight,
        color: color ?? this.color,
        weight: weight ?? this.weight,
      );

  TextStyle toTextStyle(PixelGrid g) {
    final family = switch (font) {
      PixelFont.sans => 'AtkinsonHyperlegible',
      PixelFont.mono => 'JetBrainsMono',
    };
    final variable = font == PixelFont.mono;
    final fs = fontSize(g);
    return TextStyle(
      fontFamily: family,
      package: 'ms_ui',
      fontSize: fs,
      height: g.d(lineHeight) / fs,
      leadingDistribution: TextLeadingDistribution.even,
      color: color,
      fontWeight: FontWeight.values[((weight ~/ 100) - 1).clamp(0, 8)],
      fontVariations: variable ? [ui.FontVariation('wght', weight.toDouble())] : null,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PixelTextStyle &&
      other.font == font &&
      other.size == size &&
      other.lineHeight == lineHeight &&
      other.color == color &&
      other.weight == weight;

  @override
  int get hashCode => Object.hash(font, size, lineHeight, color, weight);
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
  void updateRenderObject(BuildContext context, RenderPixelText renderObject) =>
      renderObject.update(PixelScope.of(context), text, style, snapBaseline);
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
    text: TextSpan(text: _text, style: _style.toTextStyle(_g)),
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

  double _naturalWidth() {
    // painter a parte: quello di disegno resta impaginato con il vincolo
    final tp = TextPainter(
      text: TextSpan(text: _text, style: _style.toTextStyle(_g)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return _g.ceilToUnit(w);
  }

  @override
  double computeMinIntrinsicWidth(double height) => _naturalWidth();

  @override
  double computeMaxIntrinsicWidth(double height) => _naturalWidth();

  @override
  double computeMinIntrinsicHeight(double width) => _g.d(_style.lineHeight);

  @override
  double computeMaxIntrinsicHeight(double width) => _g.d(_style.lineHeight);

  @override
  double computeDistanceToActualBaseline(TextBaseline baseline) {
    final tp = _painter..layout(maxWidth: constraints.maxWidth);
    return (size.height - tp.height) / 2 + tp.computeDistanceToActualBaseline(baseline);
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (debugHideText) return;
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
