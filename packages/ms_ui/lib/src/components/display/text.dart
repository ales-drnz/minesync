// Aiuti tipografici di ms.css: .ms-display, .ms-h1/2/3, .ms-lg, .ms-body,
// .ms-small, .ms-label, .ms-mono, .ms-num (cifre tabellari), .ms-text-2/3
// e i colori di stato (.ms-t-*), più .ms-eyebrow, .ms-code e .ms-divider.
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'common.dart';

/// Ruolo del testo (classi tipografiche del canvas).
enum MsTextKind {
  /// `.ms-display`: grassetto 40/48.
  display,

  /// `.ms-h1`: grassetto 32/40.
  h1,

  /// `.ms-h2`: grassetto 24/32.
  h2,

  /// `.ms-h3`: grassetto 20/28.
  h3,

  /// `.ms-lg`: 18/28.
  lg,

  /// `.ms-body`: 16/24 (predefinito).
  body,

  /// `.ms-small`: 14/20.
  small,

  /// `.ms-label`: grassetto 15/24 (teste dei pannelli, eyebrow).
  label,

  /// Etichetta piccola (grassetto 14/20): badge, pillole, lock,
  /// intestazioni di tabella, etichette delle statistiche.
  labelSmall,

  /// `.ms-mono`: JetBrains Mono 14/20.
  mono,
}

/// Colore del testo (`.ms-text-2`, `.ms-text-3`, `.ms-t-*`).
enum MsTextTone { primary, secondary, tertiary, ok, warn, err, info, accent }

/// Colore di [tone] nello schema [c].
Color msToneColor(MsColors c, MsTextTone tone) => switch (tone) {
  MsTextTone.primary => c.text,
  MsTextTone.secondary => c.text2,
  MsTextTone.tertiary => c.text3,
  MsTextTone.ok => c.ok,
  MsTextTone.warn => c.warn,
  MsTextTone.err => c.err,
  MsTextTone.info => c.info,
  MsTextTone.accent => c.accentInk,
};

/// Stile pixel per [kind] secondo il tema corrente.
PixelTextStyle msTextStyle(BuildContext context, MsTextKind kind, Color color, {int? weight}) {
  final t = MsTheme.typographyOf(context);
  return switch (kind) {
    MsTextKind.display => t.style(MsTextRole.display, color, weight: weight ?? 700),
    MsTextKind.h1 => t.style(MsTextRole.h1, color, weight: weight ?? 700),
    MsTextKind.h2 => t.style(MsTextRole.h2, color, weight: weight ?? 700),
    MsTextKind.h3 => t.style(MsTextRole.h3, color, weight: weight ?? 700),
    MsTextKind.lg => t.style(MsTextRole.lg, color, weight: weight),
    MsTextKind.body => t.style(MsTextRole.md, color, weight: weight),
    MsTextKind.small => t.style(MsTextRole.sm, color, weight: weight),
    MsTextKind.label => t.style(MsTextRole.label, color, weight: weight),
    MsTextKind.labelSmall =>
      t.style(MsTextRole.label, color, weight: weight).copyWith(size: 14, lineHeight: 20),
    MsTextKind.mono => t.style(MsTextRole.mono, color, weight: weight),
  };
}

/// Pezzo di testo per [MsText.rich]: [strong] corrisponde a `<strong>`.
@immutable
class MsSpan {
  const MsSpan(this.text, {this.strong = false});

  final String text;
  final bool strong;
}

/// Testo del design system.
///
/// Su una sola riga ([maxLines] = 1, senza cifre tabellari) usa [PixelText]:
/// origine e linea di base sul pixel fisico. Altrimenti usa [Text] con lo
/// stesso stile, a capo automatico.
class MsText extends StatelessWidget {
  const MsText(
    this.text, {
    super.key,
    this.kind = MsTextKind.body,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.tabular = false,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : spans = null,
       strongWeight = 700,
       strongColor = null;

  /// Testo con parti in grassetto (`<strong>`), di peso [strongWeight] e
  /// colore [strongColor] (predefinito: lo stesso del testo).
  const MsText.rich(
    List<MsSpan> this.spans, {
    super.key,
    this.kind = MsTextKind.body,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.tabular = false,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
    this.strongWeight = 700,
    this.strongColor,
  }) : text = '';

  const MsText.display(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.display,
       tabular = false,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  const MsText.h1(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.h1,
       tabular = false,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  const MsText.h2(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.h2,
       tabular = false,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  const MsText.h3(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.h3,
       tabular = false,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  const MsText.small(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.tabular = false,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.small,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  /// Etichetta in grassetto su una riga.
  const MsText.label(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.label,
       tabular = false,
       maxLines = 1,
       align = TextAlign.start,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  const MsText.mono(
    this.text, {
    super.key,
    this.tone = MsTextTone.primary,
    this.color,
    this.weight,
    this.maxLines,
    this.align = TextAlign.start,
    this.semanticsLabel,
    this.lineHeight,
  }) : kind = MsTextKind.mono,
       tabular = false,
       spans = null,
       strongWeight = 700,
       strongColor = null;

  /// Interlinea in px di design al posto di quella del ruolo (righe
  /// compatte, es. titolo e descrizione di una riga di impostazione).
  final double? lineHeight;

  final String text;
  final List<MsSpan>? spans;
  final MsTextKind kind;
  final MsTextTone tone;

  /// Colore esplicito (prevale su [tone]).
  final Color? color;
  final int? weight;

  /// Cifre a larghezza fissa (`.ms-num`).
  final bool tabular;
  final int? maxLines;
  final TextAlign align;
  final String? semanticsLabel;
  final int strongWeight;
  final Color? strongColor;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final fg = color ?? msToneColor(c, tone);
    final base = msTextStyle(context, kind, fg, weight: weight);
    final style = lineHeight == null ? base : base.copyWith(lineHeight: lineHeight);
    final g = PixelScope.of(context);
    final rich = spans;
    // le etichette hanno l'iniziale maiuscola (le stringhe arrivano come
    // "salvato", "libero": prima le metteva tutte in maiuscolo il componente)
    final text = kind == MsTextKind.label || kind == MsTextKind.labelSmall
        ? msSentenceCase(this.text)
        : this.text;
    if (rich == null && maxLines == 1 && !tabular && align == TextAlign.start) {
      return Semantics(
        label: semanticsLabel ?? text,
        excludeSemantics: true,
        child: PixelText(text, style: style),
      );
    }
    var ts = style.toTextStyle(g);
    if (tabular) ts = ts.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final strong = ts.copyWith(
      color: strongColor,
      fontWeight: FontWeight.values[((strongWeight ~/ 100) - 1).clamp(0, 8)],
      fontVariations: ts.fontVariations == null
          ? null
          : [FontVariation('wght', strongWeight.toDouble())],
    );
    final span = rich == null
        ? TextSpan(text: text, style: ts)
        : TextSpan(
            style: ts,
            children: [
              for (final s in rich) TextSpan(text: s.text, style: s.strong ? strong : null),
            ],
          );
    if (debugHideText) return Opacity(opacity: 0, child: Text.rich(span, maxLines: maxLines));
    return Text.rich(
      span,
      maxLines: maxLines,
      overflow: maxLines == null ? TextOverflow.clip : TextOverflow.ellipsis,
      textAlign: align,
      semanticsLabel: semanticsLabel,
      textScaler: TextScaler.noScaling,
    );
  }
}

/// `.ms-eyebrow`: quadratino d'accento e etichetta in --ms-text-2. In uno
/// spazio stretto l'etichetta si tronca con i puntini.
class MsEyebrow extends StatelessWidget {
  const MsEyebrow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PixelBox(
          width: 10,
          height: 10,
          repaintKey: c,
          painter: (p, w, h) => p.accentSquare(0, 0, c.accent, c.accentLo),
        ),
        const PixelGap(6, 0), // 8 px dal quadrato (8 + ombra 2)
        Flexible(child: MsText.label(text, tone: MsTextTone.secondary)),
      ],
    );
  }
}

/// `.ms-code`: codice in linea su fondo incassato.
class MsCode extends StatelessWidget {
  const MsCode(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    return PixelFrame(
      padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
      repaintKey: c,
      painter: (p, w, h) {
        p.rect(0, 0, w, h, c.inset);
        p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
      },
      child: MsText(text, kind: MsTextKind.mono, weight: 500, maxLines: 1),
    );
  }
}

/// `.ms-divider`: linea di 2 px in ombra con filo di luce sotto (4 px in
/// tutto), larga quanto il genitore.
class MsDivider extends StatelessWidget {
  const MsDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.hasBoundedWidth ? (box.maxWidth / g.unit + 1e-6).floorToDouble() * 2 : 0.0;
        return PixelBox(
          width: w,
          height: 4,
          repaintKey: c,
          painter: (p, w, h) {
            p.rect(0, 0, w, 2, c.pxShadow);
            p.rect(0, 2, w, 2, c.pxLight);
          },
        );
      },
    );
  }
}
