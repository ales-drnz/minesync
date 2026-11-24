// Cursore (.ms-slider): binario incassato riempito a lingotti 6+2 di
// accento, manopola a blocchetto 20x32. Trascinamento, clic sul binario e
// tastiera (frecce, Pagina su/giù, Inizio/Fine).
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../tokens.g.dart';
import 'core.dart';

/// Pixel range slider (`.ms-slider`, 44 px high, takes the available width).
///
/// [value] goes from [min] to [max]; with [step] it snaps to multiples of
/// it (arrows move by one step, PageUp/PageDown by a tenth of the range).
/// Disabled when [onChanged] is null (the fill disappears, as in the CSS).
class MsSlider extends StatefulWidget {
  const MsSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.step,
    this.semanticLabel,
    this.semanticFormatter,
    this.focusNode,
    this.autofocus = false,
    this.forcedStates,
  }) : assert(max > min);

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final double? step;
  final String? semanticLabel;

  /// Value read by screen readers (e.g. `(v) => '$v Mbit/s'`); defaults to
  /// a percentage of the range.
  final String Function(double value)? semanticFormatter;
  final FocusNode? focusNode;
  final bool autofocus;
  final MsStates? forcedStates;

  @override
  State<MsSlider> createState() => _MsSliderState();
}

class _MsSliderState extends State<MsSlider> {
  bool _focus = false;

  bool get _enabled => widget.onChanged != null;
  double get _range => widget.max - widget.min;
  double get _t => ((widget.value - widget.min) / _range).clamp(0.0, 1.0);
  double get _keyStep => widget.step ?? _range / 20;

  double _snap(double v) {
    var x = v.clamp(widget.min, widget.max);
    final s = widget.step;
    if (s != null && s > 0) {
      x = (widget.min + ((x - widget.min) / s).round() * s).clamp(widget.min, widget.max);
    }
    return x;
  }

  void _set(double v) {
    final x = _snap(v);
    if (x != widget.value) widget.onChanged?.call(x);
  }

  void _fromLocal(Offset local, double width, PixelGrid g) {
    final thumb = g.d(20);
    final t = ((local.dx - thumb / 2) / (width - thumb)).clamp(0.0, 1.0);
    _set(widget.min + t * _range);
  }

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final g = PixelScope.of(context);
    final enabled = _enabled;
    final focus = enabled && (widget.forcedStates?.focused ?? _focus);
    String fmt(double v) =>
        widget.semanticFormatter?.call(v) ??
        '${(((v - widget.min) / _range).clamp(0.0, 1.0) * 100).round()}%';
    final big = _range / 10;
    return Semantics(
      slider: true,
      enabled: enabled,
      label: widget.semanticLabel,
      value: fmt(widget.value),
      increasedValue: enabled ? fmt(_snap(widget.value + _keyStep)) : null,
      decreasedValue: enabled ? fmt(_snap(widget.value - _keyStep)) : null,
      onIncrease: enabled ? () => _set(widget.value + _keyStep) : null,
      onDecrease: enabled ? () => _set(widget.value - _keyStep) : null,
      child: FocusableActionDetector(
        enabled: enabled,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
        onShowFocusHighlight: (v) => setState(() => _focus = v),
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.arrowRight): _Nudge(_keyStep),
          const SingleActivator(LogicalKeyboardKey.arrowUp): _Nudge(_keyStep),
          const SingleActivator(LogicalKeyboardKey.arrowLeft): _Nudge(-_keyStep),
          const SingleActivator(LogicalKeyboardKey.arrowDown): _Nudge(-_keyStep),
          const SingleActivator(LogicalKeyboardKey.pageUp): _Nudge(big),
          const SingleActivator(LogicalKeyboardKey.pageDown): _Nudge(-big),
          const SingleActivator(LogicalKeyboardKey.home): _Nudge(-_range),
          const SingleActivator(LogicalKeyboardKey.end): _Nudge(_range),
        },
        actions: {_Nudge: CallbackAction<_Nudge>(onInvoke: (n) => _set(widget.value + n.delta))},
        child: LayoutBuilder(
          builder: (context, cons) {
            final width = cons.hasBoundedWidth ? cons.maxWidth : g.d(320);
            // larghezza in unità intere
            final wUnits = (width / g.unit + 1e-6).floor();
            final wDesign = wUnits * 2.0;
            final logical = wUnits * g.unit;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: enabled ? (d) => _fromLocal(d.localPosition, logical, g) : null,
              onHorizontalDragUpdate: enabled
                  ? (d) => _fromLocal(d.localPosition, logical, g)
                  : null,
              child: PixelBox(
                width: wDesign,
                height: 44,
                repaintKey: (_t, enabled, focus, c.accent),
                // spenta resta al suo valore, in grigio: dice quanto varrebbe
                painter: (p, w, h) => _paint(p, w, c, _t, focus, enabled),
              ),
            );
          },
        ),
      ),
    );
  }
}

void _paint(PixelCanvas p, double w, MsColors c, double t, bool focus, bool enabled) {
  // binario alto 12 al centro, con contorno esterno: lo si tiene dentro
  // il box (2 px di margine ai lati).
  const ty = 16.0;
  const tx = 2.0;
  final tw = w - 4;
  p.ring(tx, ty, tw, 12, c.pxOutline);
  p.rect(tx, ty, tw, 12, c.inset);
  final fill = ((tw * t) / 2).round() * 2.0;
  for (var x = 0.0; x < fill; x += 8) {
    p.rect(tx + x, ty, (fill - x).clamp(0, 6), 12, enabled ? c.accent : c.text3);
    if (fill - x > 6) {
      p.rect(tx + x + 6, ty, (fill - x - 6).clamp(0, 2), 12, enabled ? c.accentLo : c.pxShadow);
    }
  }
  // rilievo interno sopra al riempimento (box-shadow inset)
  p.rect(tx, ty + 10, tw, 2, c.pxLight);
  p.rect(tx + tw - 2, ty, 2, 12, c.pxLight);
  p.rect(tx, ty, tw, 2, c.pxShadow);
  p.rect(tx, ty, 2, 12, c.pxShadow);
  // manopola 20x32, centrata sul valore
  final kx = 2 + (((tw - 20) * t) / 2).round() * 2.0;
  const ky = 6.0;
  p.ring(kx, ky, 20, 32, c.pxOutline);
  p.rect(kx, ky, 20, 32, c.panelHi);
  p.rect(kx, ky, 20, 2, c.pxLight);
  p.rect(kx, ky + 28, 20, 4, c.pxShadow);
  if (focus) p.outline(-2, -2, w + 4, 48, c.focus);
}

class _Nudge extends Intent {
  const _Nudge(this.delta);
  final double delta;
}
