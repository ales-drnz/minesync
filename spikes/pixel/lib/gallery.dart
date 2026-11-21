// Galleria dei componenti dello spike. Le sezioni sono separate da
// RepaintBoundary con chiave, così i golden possono catturarle una per una.
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import 'ms/components.dart';
import 'ms/icons.dart';
import 'ms/tokens.dart';
import 'pixel/grid.dart';
import 'pixel/render.dart';
import 'pixel/text.dart';
import 'specimen_list.dart';

PixelFont _font(String f) => switch (f) {
      'silkscreen' => PixelFont.silkscreen,
      'silkscreen_orig' => PixelFont.silkscreenOrig,
      'pixelify' => PixelFont.pixelify,
      _ => PixelFont.mono,
    };

/// Sfondo pieno --ms-bg (i figli partono da un'origine allineata).
class MsBackground extends StatelessWidget {
  const MsBackground({super.key, required this.child, this.padding = 16});
  final Widget child;
  final double padding;
  @override
  Widget build(BuildContext context) {
    return PixelFrame(
      padding: EdgeInsets.all(padding),
      painter: (c, w, h) => c.rect(0, 0, w, h, Ms.bg),
      child: child,
    );
  }
}

/// Pulsanti nei quattro stati. [showText] falso = solo geometria + icone.
class ButtonsSection extends StatelessWidget {
  const ButtonsSection({super.key, this.showText = true});
  final bool showText;
  @override
  Widget build(BuildContext context) {
    final l = showText ? 'Gioca' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsPlayButton(label: l, forced: const BtnLook()),
        const PixelGap(16, 0),
        MsPlayButton(label: l, forced: const BtnLook(hover: true)),
        const PixelGap(16, 0),
        MsPlayButton(label: l, forced: const BtnLook(pressed: true)),
        const PixelGap(16, 0),
        MsPlayButton(label: l, forced: const BtnLook(focus: true)),
      ],
    );
  }
}

/// Pannello in rilievo con slot, barra a lingotti e icone.
class PanelSection extends StatelessWidget {
  const PanelSection({super.key, this.showText = true, this.raster});
  final bool showText;
  final Map<String, ui.Image>? raster;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    final icons = MsIcons.all.entries.toList();
    return SizedBox(
      width: g.d(560 + 8),
      child: MsPanel(
        raised: true,
        title: showText ? 'Sessione' : '',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(mainAxisSize: MainAxisSize.min, children: [
              const MsSlot(square: true, child: PixelIcon(MsIcons.lock, size: 48, color: Ms.ok)),
              const PixelGap(12, 0),
              const MsSlot(square: true, child: PixelIcon(MsIcons.gear, size: 48, color: Ms.text2)),
              const PixelGap(12, 0),
              if (raster != null)
                MsSlot(square: true, child: PixelImageIcon(raster!['globe']!, size: 48)),
            ]),
            const PixelGap(0, 16),
            const MsProgress(value: .63, width: 480),
            const PixelGap(0, 16),
            // icone vettoriali a 16 / 24 / 32
            for (final s in const [16.0, 24.0, 32.0]) ...[
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final e in icons) ...[
                  PixelIcon(e.value, size: s, color: Ms.text),
                  const PixelGap(8, 0),
                ],
              ]),
              const PixelGap(0, 8),
            ],
            // stesse icone come bitmap 8x8 con FilterQuality.none
            if (raster != null)
              Row(mainAxisSize: MainAxisSize.min, children: [
                for (final e in icons) ...[
                  PixelImageIcon(raster![e.key]!, size: 32),
                  const PixelGap(8, 0),
                ],
              ]),
            const PixelGap(0, 8),
            MsSlot(
              child: showText
                  ? const PixelText('Slot incassato · 42 GB liberi', style: MsText.body)
                  : const PixelGap(240, 24),
            ),
          ],
        ),
      ),
    );
  }
}

/// Campioni di testo su sfondo pieno (una banda per campione).
class TextSection extends StatelessWidget {
  const TextSection(this.id, {super.key});
  final String id;
  @override
  Widget build(BuildContext context) {
    final samples = textSamples[id]!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in samples) ...[
          PixelText(s.text,
              snapBaseline: s.snap,
              style: PixelTextStyle(
                  font: _font(s.font),
                  size: s.size,
                  lineHeight: s.lineHeight,
                  weight: s.weight,
                  color: Ms.text)),
          const PixelGap(0, 8),
        ],
      ],
    );
  }
}

class Gallery extends StatelessWidget {
  const Gallery({super.key, this.raster, this.lines, this.consoleController, this.consoleHeight = 240});
  final Map<String, ui.Image>? raster;
  final List<ConsoleLine>? lines;
  final ScrollController? consoleController;
  final double consoleHeight;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    return MsBackground(
      child: SizedBox(
        width: g.d(1180),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PixelText('MineSync · pixel spike  (dpr ${g.dpr}, ${g.unitPx} px fisici/unità, scala ${g.scale.toStringAsFixed(2)})',
                style: const PixelTextStyle(font: PixelFont.pixelify, size: 24, lineHeight: 32, weight: 600, color: Ms.text)),
            const PixelGap(0, 16),
            const ButtonsSection(),
            const PixelGap(0, 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                PanelSection(raster: raster),
                const PixelGap(24, 0),
                const Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextSection('text_silkscreen'),
                    TextSection('text_pixelify'),
                    TextSection('text_mono'),
                  ],
                ),
              ],
            ),
            const PixelGap(0, 16),
            MsConsole(
                lines: lines ?? demoLines(2000),
                height: consoleHeight,
                controller: consoleController),
          ],
        ),
      ),
    );
  }
}
