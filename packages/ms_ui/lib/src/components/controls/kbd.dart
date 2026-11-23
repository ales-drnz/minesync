// Tasto (.ms-kbd): scorciatoia da tastiera mostrata come un tastino pixel.
import 'package:flutter/widgets.dart';

import '../../pixel/render.dart';
import '../../pixel/text.dart';
import 'core.dart';

/// Keyboard shortcut chip (`.ms-kbd`), e.g. `MsKbd('Ctrl N')`.
class MsKbd extends StatelessWidget {
  const MsKbd(this.keys, {super.key, this.semanticLabel});

  /// Visible key text (the app localises it: "Invio" / "Enter").
  final String keys;

  /// Screen-reader text; defaults to [keys].
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = msColors(context);
    return Semantics(
      label: semanticLabel ?? keys,
      excludeSemantics: true,
      child: PixelFrame(
        outset: const EdgeInsets.all(2),
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minWidth: 24,
        minHeight: 20,
        centerX: true,
        repaintKey: (c.panelHi, c.pxOutline, c.pxShadow),
        painter: (p, w, h) {
          p.ring(0, 0, w, h, c.pxOutline);
          p.rect(0, 0, w, h, c.panelHi);
          p.rect(0, h - 2, w, 2, c.pxShadow);
        },
        child: PixelText(
          keys,
          style: PixelTextStyle(
            font: PixelFont.mono,
            size: 14,
            lineHeight: 20,
            color: c.text,
            weight: 600,
          ),
        ),
      ),
    );
  }
}
