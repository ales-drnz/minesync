// Indicatore dei passi di una procedura (.ms-steps): un quadratino per passo
// con il numero, la spunta sui passi fatti, il passo corrente pieno di
// accento con l'etichetta in grassetto, i passi futuri attenuati; trattini
// fra un passo e l'altro. Si legge come «passo X di N».
import 'package:flutter/widgets.dart';

import '../../icons/icons.dart';
import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import 'core.dart';

/// One step of an [MsSteps].
@immutable
final class MsStep {
  const MsStep(this.label, {this.skipped = false});

  final String label;

  /// Step not part of the current path (e.g. no mods for a vanilla server):
  /// shown muted with a dash, whatever its position.
  final bool skipped;
}

/// Step indicator of a multi-step procedure (`.ms-steps`).
///
/// Steps before [current] are done (check), [current] is filled with the
/// accent and its label is bold, later steps are muted. A [current] equal to
/// the number of steps marks them all as done. Screen readers hear one node:
/// [semanticLabel] with [positionLabel] (default "2 / 4") and the current
/// step's label as value.
class MsSteps extends StatelessWidget {
  const MsSteps({
    super.key,
    required this.steps,
    required this.current,
    this.semanticLabel,
    this.positionLabel,
  });

  final List<MsStep> steps;
  final int current;
  final String? semanticLabel;

  /// Localized "step [position] of [total]".
  final String Function(int position, int total)? positionLabel;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    final n = steps.length;
    final at = current.clamp(0, n);
    final pos = (positionLabel ?? (p, t) => '$p / $t')((at + 1).clamp(1, n), n);
    return Semantics(
      container: true,
      label: semanticLabel,
      value: at < n ? '$pos, ${steps[at].label}' : pos,
      child: ExcludeSemantics(
        child: Wrap(
          spacing: PixelScope.of(context).d(8),
          runSpacing: PixelScope.of(context).d(8),
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (var i = 0; i < n; i++) ...[
              if (i > 0)
                PixelBox(
                  width: 16,
                  height: 2,
                  repaintKey: (i <= at, c.accent, c.text3),
                  painter: (p, w, h) => p.rect(0, 0, w, h, i <= at ? c.accent : c.text3),
                ),
              _step(context, i, at),
            ],
          ],
        ),
      ),
    );
  }

  Widget _step(BuildContext context, int i, int at) {
    final c = msColors(context);
    final st = steps[i];
    final done = !st.skipped && i < at;
    final now = !st.skipped && i == at;
    final (fill, ring, fg) = now
        ? (c.accent, c.pxOutline, c.onAccent)
        : done
        ? (c.accentBg, c.accent, c.accentInk)
        : (c.inset, c.text3, c.text3);
    final Widget mark = done
        ? msIconSlot(context, const MsIcon(MsIcons.check), fg, size: 12)
        : PixelText(
            st.skipped ? '–' : '${i + 1}',
            style: msText(context, MsTextRole.sm, fg, weight: 700),
          );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PixelFrame(
          outset: const EdgeInsets.all(2),
          minWidth: 20,
          minHeight: 20,
          centerX: true,
          centerY: true,
          repaintKey: (fill, ring),
          painter: (p, w, h) {
            p.ring(0, 0, w, h, ring);
            p.rect(0, 0, w, h, fill);
          },
          child: mark,
        ),
        const PixelGap(8, 0),
        PixelText(
          st.label,
          style: msText(
            context,
            MsTextRole.md,
            now ? c.text : (done ? c.text2 : c.text3),
            weight: now ? 700 : 600,
          ),
        ),
      ],
    );
  }
}
