// Barra di progresso "a lingotti" (.ms-progress, --ok/--warn/--err, --thin,
// --indeterminate) e riga di dettagli (.ms-progress-meta).
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'common.dart';

/// Colore del riempimento di [MsProgress].
enum MsProgressTone { accent, ok, warn, err }

/// Barra di progresso a lingotti (segmenti di 10 px con fuga di 2 px) in uno
/// slot incassato. [value] tra 0 e 1; nullo = indeterminata (un blocco che
/// scorre a 16 scatti; con le animazioni ridotte diventa una barra piena
/// attenuata).
///
/// Il riempimento segue i cambi di valore a 4 scatti in --ms-dur-3.
/// Riempie la larghezza disponibile.
class MsProgress extends StatefulWidget {
  const MsProgress({
    super.key,
    required this.value,
    this.tone = MsProgressTone.accent,
    this.thin = false,
    this.semanticLabel,
    this.valueLabel,
  });

  /// Indeterminata.
  const MsProgress.indeterminate({
    super.key,
    this.tone = MsProgressTone.accent,
    this.thin = false,
    this.semanticLabel,
  }) : value = null,
       valueLabel = null;

  final double? value;
  final MsProgressTone tone;

  /// `.ms-progress--thin`: 16 px, senza filo chiaro.
  final bool thin;

  /// Cosa avanza (es. "Download").
  final String? semanticLabel;

  /// Valore letto dalle tecnologie assistive (predefinito: percentuale
  /// intera seguita da "%").
  final String? valueLabel;

  @override
  State<MsProgress> createState() => _MsProgressState();
}

class _MsProgressState extends State<MsProgress> with TickerProviderStateMixin {
  late final AnimationController _move = AnimationController(vsync: this, duration: MsDuration.d3);
  late final AnimationController _indet = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );
  double _from = 0;
  double _to = 0;

  @override
  void initState() {
    super.initState();
    _from = _to = (widget.value ?? 0).clamp(0, 1);
    _move.value = 1;
  }

  bool get _reduced => MsTheme.reducedMotionOf(context);

  void _syncIndet() {
    final run = widget.value == null && !_reduced;
    if (run && !_indet.isAnimating) {
      _indet.repeat();
    } else if (!run && _indet.isAnimating) {
      _indet
        ..stop()
        ..value = 0;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncIndet();
  }

  @override
  void didUpdateWidget(MsProgress old) {
    super.didUpdateWidget(old);
    _syncIndet();
    final v = (widget.value ?? 0).clamp(0.0, 1.0);
    if (v != _to) {
      _from = _shown;
      _to = v;
      if (_reduced) {
        _from = v;
        _move.value = 1;
      } else {
        _move.forward(from: 0);
      }
    }
  }

  // steps(4, end): il valore avanza a quattro scatti.
  double get _shown {
    final t = _move.value >= 1 ? 1.0 : (_move.value * 4).floorToDouble() / 4;
    return _from + (_to - _from) * t;
  }

  @override
  void dispose() {
    _move.dispose();
    _indet.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final (fill, hi) = switch (widget.tone) {
      MsProgressTone.accent => (c.accent, c.accentHi),
      MsProgressTone.ok => (c.ok, c.ok),
      MsProgressTone.warn => (c.warn, c.warn),
      MsProgressTone.err => (c.err, c.err),
    };
    final h = widget.thin ? 16.0 : 24.0;
    final indeterminate = widget.value == null;
    final reduced = _reduced;
    final pct = ((widget.value ?? 0).clamp(0, 1) * 100).round();
    final bar = LayoutBuilder(
      builder: (context, box) {
        final total = box.hasBoundedWidth
            ? (box.maxWidth / g.unit + 1e-6).floorToDouble() * 2
            : 324.0;
        final w = total - 4; // contorno di 2 px per lato
        return AnimatedBuilder(
          animation: Listenable.merge([_move, _indet]),
          builder: (context, _) {
            final shown = _shown;
            final step = (_indet.value * 16).floor().clamp(0, 15);
            return PixelBox(
              width: total,
              height: h + 4,
              repaintKey: (shown, step, widget.tone, widget.thin, indeterminate, reduced, c),
              painter: (p0, _, _) {
                final p = p0.shiftPhys(p0.g.unitPx, p0.g.unitPx);
                p.ring(0, 0, w, h, c.pxOutline);
                p.rect(0, 0, w, h, c.inset);
                p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
                final inner = w - 8;
                final fh = h - 8;
                void ingots(double from, double to, double origin, Color a, Color b) {
                  // lingotti 10 + 2 a partire da [origin], tagliati a [from, to)
                  for (var x = origin; x < to; x += 12) {
                    final l = x < from ? from : x;
                    final r = (x + 10) > to ? to : x + 10;
                    if (r <= l) continue;
                    p.rect(4 + l, 4, r - l, fh, a);
                    if (!widget.thin) p.rect(4 + l, 4, r - l, 4, b);
                  }
                }

                if (!indeterminate) {
                  final fw = ((inner * shown) / 2).round() * 2.0;
                  ingots(0, fw, 0, fill, hi);
                } else if (reduced) {
                  ingots(0, inner, 0, msBlend(fill, c.inset, .6), msBlend(hi, c.inset, .6));
                } else {
                  final cw = ((inner * .36) / 2).round() * 2.0;
                  final x = ((cw * (-1 + 3.8 * step / 16)) / 2).round() * 2.0;
                  ingots(x < 0 ? 0 : x, (x + cw) > inner ? inner : x + cw, x, fill, hi);
                }
              },
            );
          },
        );
      },
    );
    return Semantics(
      label: widget.semanticLabel,
      value: indeterminate ? null : (widget.valueLabel ?? '$pct%'),
      role: indeterminate ? null : SemanticsRole.progressBar,
      minValue: indeterminate ? null : '0',
      maxValue: indeterminate ? null : '100',
      child: ExcludeSemantics(child: bar),
    );
  }
}

/// Riga di dettagli sopra o sotto una barra (`.ms-progress-meta`): due
/// estremi ai lati, il primo si restringe se lo spazio non basta. Il testo va composto con
/// `MsText.rich(kind: MsTextKind.small, tone: MsTextTone.secondary,
/// strongWeight: 600, strongColor: text)`.
class MsProgressMeta extends StatelessWidget {
  const MsProgressMeta({super.key, required this.start, this.end});

  final Widget start;
  final Widget? end;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: start),
        if (end != null) ...[const PixelGap(12, 0), end!],
      ],
    );
  }
}
