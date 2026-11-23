// Texture originali di ms.css (.ms-tex-grass/dirt/stone/wood/slate/
// amethyst/copper), sfondo a blocchi (.ms-bg-blocks) e striscia orizzonte
// (.ms-horizon). Nel CSS sono gradienti a gradini con colori semitrasparenti;
// qui ogni cella di 2 px di design viene calcolata componendo gli strati in
// un colore pieno, e le celle uguali vicine si fondono in rettangoli.
// Risultato: solo rettangoli allineati alla griglia, nessuna fusione nel
// motore (pixel puro).
import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import '../../tokens.g.dart';

/// Direzione di uno strato a strisce (angoli di `linear-gradient`).
enum _Dir {
  /// 90deg: da sinistra verso destra.
  right,

  /// 0deg: dal basso verso l'alto.
  up,

  /// 180deg: dall'alto verso il basso.
  down,

  /// 45deg: verso l'alto a destra.
  diagUp,

  /// -45deg: verso l'alto a sinistra.
  diagLeft,
}

@immutable
class _Stop {
  const _Stop(this.from, this.to, this.color);
  final double from;
  final double to;
  final Color color;
}

/// Strato di gradiente a gradini; [period] nullo = non ripetuto; [maxY]
/// limita lo strato alle prime righe (`background-size: 100% 16px`).
@immutable
class _Layer {
  const _Layer(this.dir, this.stops, {this.period, this.maxY});
  final _Dir dir;
  final List<_Stop> stops;
  final double? period;
  final double? maxY;

  Color? at(double x, double y, double w, double h) {
    if (maxY != null && y >= maxY!) return null;
    final lh = maxY ?? h;
    final double p;
    switch (dir) {
      case _Dir.right:
        p = x;
      case _Dir.up:
        p = lh - y;
      case _Dir.down:
        p = y;
      case _Dir.diagUp || _Dir.diagLeft:
        // linea del gradiente CSS: direzione (sin θ, −cos θ), lunghezza
        // |w sin θ| + |h cos θ|, centrata sul riquadro
        final s = dir == _Dir.diagUp ? math.sqrt1_2 : -math.sqrt1_2;
        const k = math.sqrt1_2;
        final len = (w * s).abs() + (lh * k).abs();
        p = (x - w / 2) * s - (y - lh / 2) * k + len / 2;
    }
    var q = p;
    if (period != null) {
      q = p % period!;
      if (q < 0) q += period!;
    }
    for (final st in stops) {
      if (q >= st.from && q < st.to) return st.color;
    }
    return null;
  }
}

/// Motivo pixel: colore di base e strati (il primo è in cima, come in
/// `background-image`). Si disegna a celle di 2 px di design.
@immutable
class MsPattern {
  const MsPattern._(this._base, this._layers, this._key);

  final Color? _base;
  final List<_Layer> _layers;
  final Object _key;

  /// Texture [kind] (colori fissi, uguali in tutti gli schemi).
  factory MsPattern.texture(MsTextureKind kind) => switch (kind) {
    MsTextureKind.dirt => MsPattern._(const Color(0xFF6B4A2E), _dirt, kind),
    MsTextureKind.grass => MsPattern._(const Color(0xFF6B4A2E), [
      const _Layer(_Dir.down, [_Stop(0, 4, Color(0xFF7CCF4A)), _Stop(4, 12, Color(0xFF5FAE35))]),
      const _Layer(
        _Dir.right,
        [
          _Stop(0, 4, Color(0xFF5FAE35)),
          _Stop(8, 12, Color(0xFF4C9A2A)),
          _Stop(12, 16, Color(0xFF5FAE35)),
        ],
        period: 24,
        maxY: 16,
      ),
      ..._dirt,
    ], kind),
    MsTextureKind.stone => MsPattern._(const Color(0xFF6F747A), const [
      _Layer(_Dir.right, [
        _Stop(0, 4, Color(0x33000000)),
        _Stop(16, 20, Color(0x1AFFFFFF)),
      ], period: 36),
      _Layer(_Dir.up, [
        _Stop(0, 4, Color(0x14FFFFFF)),
        _Stop(12, 16, Color(0x2E000000)),
      ], period: 28),
    ], kind),
    MsTextureKind.wood => MsPattern._(const Color(0xFF9A6B3C), const [
      _Layer(_Dir.up, [_Stop(0, 4, Color(0xFF6E4724))], period: 16),
      _Layer(_Dir.right, [_Stop(28, 32, Color(0xFF6E4724))], period: 64),
      _Layer(_Dir.right, [
        _Stop(0, 8, Color(0x1FFFDCAA)),
        _Stop(12, 20, Color(0x1A000000)),
      ], period: 24),
    ], kind),
    MsTextureKind.slate => MsPattern._(const Color(0xFF2B3244), const [
      _Layer(_Dir.up, [_Stop(0, 4, Color(0xFF1B2030))], period: 20),
      _Layer(_Dir.right, [
        _Stop(0, 12, Color(0x1AA0B4E6)),
        _Stop(16, 20, Color(0x33000000)),
      ], period: 40),
    ], kind),
    MsTextureKind.amethyst => MsPattern._(const Color(0xFF6D4FC2), const [
      _Layer(_Dir.diagUp, [_Stop(0, 4, Color(0x2EFFFFFF))], period: 12),
      _Layer(_Dir.diagLeft, [_Stop(0, 4, Color(0x4714083C))], period: 16),
    ], kind),
    MsTextureKind.copper => MsPattern._(const Color(0xFFB8693A), const [
      _Layer(_Dir.right, [
        _Stop(0, 4, Color(0x595AC8AA)),
        _Stop(20, 24, Color(0x2EFFD2AA)),
      ], period: 32),
      _Layer(_Dir.up, [_Stop(0, 4, Color(0x24000000))], period: 16),
    ], kind),
  };

  /// Sfondo a blocchi della pagina (`.ms-bg-blocks`) sui colori di [c].
  factory MsPattern.blocks(MsColors c) => MsPattern._(
    c.bg,
    [
      _Layer(_Dir.right, [
        _Stop(0, 4, c.texA),
        _Stop(20, 24, c.texB),
        _Stop(44, 48, c.texA),
      ], period: 64),
      _Layer(_Dir.up, [
        _Stop(0, 4, c.texB),
        _Stop(28, 32, c.texA),
        _Stop(52, 56, c.texB),
      ], period: 64),
    ],
    ('blocks', c),
  );

  /// Striscia orizzonte (`.ms-horizon`): erba su terra (prato) o cristallo
  /// d'accento su ardesia (abisso).
  factory MsPattern.horizon(MsColors c, MsPalette palette) => switch (palette) {
    MsPalette.prato => const MsPattern._(null, [
      _Layer(_Dir.down, [_Stop(0, 4, Color(0xFF7CCF4A)), _Stop(4, 8, Color(0xFF5FAE35))]),
      _Layer(_Dir.right, [_Stop(4, 8, Color(0xFF5FAE35))], period: 20, maxY: 12),
      _Layer(_Dir.right, [
        _Stop(0, 12, Color(0xFF6B4A2E)),
        _Stop(12, 16, Color(0xFF5A3D24)),
      ], period: 16),
    ], 'horizon-prato'),
    MsPalette.abisso => MsPattern._(
      null,
      [
        _Layer(_Dir.down, [_Stop(0, 4, c.accent), _Stop(4, 8, c.accentLo)]),
        const _Layer(_Dir.right, [
          _Stop(0, 12, Color(0xFF2B3244)),
          _Stop(12, 16, Color(0xFF1B2030)),
        ], period: 16),
      ],
      ('horizon-abisso', c.accent, c.accentLo),
    ),
  };

  static const _dirt = [
    _Layer(_Dir.right, [
      _Stop(0, 4, Color(0x38000000)),
      _Stop(12, 16, Color(0x1AFFE6BE)),
    ], period: 28),
    _Layer(_Dir.up, [_Stop(0, 4, Color(0x29000000)), _Stop(20, 24, Color(0x14FFE6BE))], period: 36),
  ];

  /// Colore pieno (o nullo = trasparente) della cella con centro (x, y) in
  /// un riquadro [w]×[h], in px di design.
  Color? colorAt(double x, double y, double w, double h) {
    var col = _base;
    for (var i = _layers.length - 1; i >= 0; i--) {
      final l = _layers[i].at(x, y, w, h);
      if (l == null) continue;
      col = col == null ? l : Color.alphaBlend(l, col);
    }
    return col;
  }

  /// Rettangoli (in px di design) che compongono il motivo su [w]×[h].
  List<(double, double, double, double, Color)> rects(double w, double h) {
    final cw = (w / 2).floor();
    final ch = (h / 2).floor();
    final out = <(double, double, double, double, Color)>[];
    List<(int, int, Color?)> runs(int row) {
      final r = <(int, int, Color?)>[];
      Color? cur;
      var start = 0;
      for (var x = 0; x < cw; x++) {
        final col = colorAt(x * 2 + 1, row * 2 + 1, w, h);
        if (x == 0) {
          cur = col;
        } else if (col != cur) {
          r.add((start, x, cur));
          start = x;
          cur = col;
        }
      }
      if (cw > 0) r.add((start, cw, cur));
      return r;
    }

    bool same(List<(int, int, Color?)> a, List<(int, int, Color?)> b) {
      if (a.length != b.length) return false;
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) return false;
      }
      return true;
    }

    var y = 0;
    while (y < ch) {
      final r = runs(y);
      var y2 = y + 1;
      while (y2 < ch && same(runs(y2), r)) {
        y2++;
      }
      for (final (x0, x1, col) in r) {
        if (col != null) out.add((x0 * 2.0, y * 2.0, (x1 - x0) * 2.0, (y2 - y) * 2.0, col));
      }
      y = y2;
    }
    return out;
  }

  /// Insieme dei colori usati su [w]×[h] (per i controlli di purezza).
  Set<Color> colorsFor(double w, double h) => {for (final r in rects(w, h)) r.$5};

  @override
  bool operator ==(Object other) => other is MsPattern && other._key == _key;

  @override
  int get hashCode => _key.hashCode;
}

/// Texture del canvas.
enum MsTextureKind { grass, dirt, stone, wood, slate, amethyst, copper }

/// Riquadro riempito da un [MsPattern], con un figlio facoltativo sopra.
/// Senza figlio e senza misure occupa tutto lo spazio disponibile.
/// Dimensioni arrotondate per difetto all'unità; motivo ancorato all'origine
/// allineata al pixel fisico. Decorativo: escluso dalla semantica.
class MsPatternBox extends SingleChildRenderObjectWidget {
  const MsPatternBox({super.key, required this.pattern, this.width, this.height, super.child});

  final MsPattern pattern;

  /// Misure in px di design (facoltative).
  final double? width;
  final double? height;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPattern(PixelScope.of(context), pattern, width, height);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderPattern)
      ..grid = PixelScope.of(context)
      ..pattern = pattern
      ..fixedWidth = width
      ..fixedHeight = height;
  }
}

class _RenderPattern extends RenderProxyBox {
  _RenderPattern(this._grid, this._pattern, this._w, this._h);

  PixelGrid _grid;
  set grid(PixelGrid v) {
    if (v == _grid) return;
    _grid = v;
    _cache = null;
    markNeedsLayout();
  }

  MsPattern _pattern;
  set pattern(MsPattern v) {
    if (v == _pattern) return;
    _pattern = v;
    _cache = null;
    markNeedsPaint();
  }

  double? _w;
  set fixedWidth(double? v) {
    if (v == _w) return;
    _w = v;
    markNeedsLayout();
  }

  double? _h;
  set fixedHeight(double? v) {
    if (v == _h) return;
    _h = v;
    markNeedsLayout();
  }

  (double, double, List<(double, double, double, double, Color)>)? _cache;

  double _floor(double logical) => (logical / _grid.unit + 1e-6).floorToDouble() * _grid.unit;

  @override
  void performLayout() {
    final g = _grid;
    BoxConstraints inner = constraints;
    if (_w != null) inner = inner.tighten(width: g.d(_w!));
    if (_h != null) inner = inner.tighten(height: g.d(_h!));
    Size s;
    if (child != null) {
      child!.layout(inner, parentUsesSize: true);
      s = child!.size;
    } else {
      s = Size(
        inner.hasBoundedWidth ? inner.maxWidth : inner.minWidth,
        inner.hasBoundedHeight ? inner.maxHeight : inner.minHeight,
      );
    }
    size = constraints.constrain(Size(_floor(s.width), _floor(s.height)));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final g = _grid;
    final w = size.width / g.unit * 2;
    final h = size.height / g.unit * 2;
    var cache = _cache;
    if (cache == null || cache.$1 != w || cache.$2 != h) {
      cache = _cache = (w, h, _pattern.rects(w, h));
    }
    final c = PixelCanvas(context.canvas, g, offset + pixelSnapDelta(this, g));
    for (final (x, y, rw, rh, col) in cache.$3) {
      c.rect(x, y, rw, rh, col);
    }
    super.paint(context, offset);
  }
}

/// Texture originale (`.ms-tex-*`): solo decorativa, mai testo sopra.
class MsTexture extends StatelessWidget {
  const MsTexture(this.kind, {super.key, this.width, this.height});

  final MsTextureKind kind;

  /// Misure in px di design; senza, riempie lo spazio disponibile.
  final double? width;
  final double? height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: MsPatternBox(pattern: MsPattern.texture(kind), width: width, height: height),
  );
}

/// Sfondo di pagina a blocchi (`.ms-bg-blocks`) dietro a [child].
class MsBlocksBackground extends StatelessWidget {
  const MsBlocksBackground({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) =>
      MsPatternBox(pattern: MsPattern.blocks(MsTheme.colorsOf(context)), child: child);
}

/// Striscia decorativa "orizzonte" (`.ms-horizon`) alta 16 px, larga quanto
/// il genitore; segue la palette del tema.
class MsHorizon extends StatelessWidget {
  const MsHorizon({super.key});

  @override
  Widget build(BuildContext context) {
    final t = MsTheme.of(context);
    return ExcludeSemantics(
      child: MsPatternBox(pattern: MsPattern.horizon(t.colors, t.palette), height: 16),
    );
  }
}
