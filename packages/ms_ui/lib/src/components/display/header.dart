// Header dell'hub web (.ms-header con __brand, __ver, __nav, __link,
// __end) e layout di servizio (.ms-stack, .ms-row, .ms-spacer).
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../pixel/text.dart';
import '../../theme.dart';
import 'common.dart';
import 'layout.dart';
import 'text.dart';

/// Header dell'hub web (`.ms-header`): alto almeno 64 px su --ms-bg-2 con
/// linea di contorno in basso; marchio, navigazione e gruppo finale (stato,
/// utente, lingua, tema). La navigazione scorre in orizzontale se non entra.
class MsHeader extends StatelessWidget {
  const MsHeader({super.key, this.brand, this.nav = const [], this.end = const [], this.navLabel});

  /// Di solito [MsHeaderBrand].
  final Widget? brand;

  /// Voci di navigazione, di solito [MsHeaderLink].
  final List<Widget> nav;

  /// Elementi a destra (`.ms-header__end`), a 12 px l'uno dall'altro.
  final List<Widget> end;

  /// Etichetta della navigazione per le tecnologie assistive.
  final String? navLabel;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return MsUnitWidth(
      child: PixelFrame(
        minHeight: 64,
        padding: const EdgeInsets.symmetric(horizontal: 24),
        repaintKey: c,
        painter: (p, w, h) {
          p.rect(0, 0, w, h, c.bg2);
          p.rect(0, h - 2, w, 2, c.pxOutline);
        },
        child: SizedBox(
          height: g.d(64),
          child: Row(
            children: [
              if (brand != null) ...[brand!, const PixelGap(24, 0)],
              Expanded(
                child: Semantics(
                  container: true,
                  label: navLabel,
                  explicitChildNodes: true,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: g.d(4),
                      children: nav,
                    ),
                  ),
                ),
              ),
              if (end.isNotEmpty) ...[
                const PixelGap(24, 0),
                Row(mainAxisSize: MainAxisSize.min, spacing: g.d(12), children: end),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Marchio dell'header (`.ms-header__brand`): logo, nome (grassetto
/// 20/28) e versione in monospazio 13/16.
class MsHeaderBrand extends StatelessWidget {
  const MsHeaderBrand({super.key, required this.name, this.logo, this.version, this.onTap});

  final String name;
  final Widget? logo;
  final String? version;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final ver = msTextStyle(
      context,
      MsTextKind.mono,
      c.text2,
      weight: 500,
    ).copyWith(size: 13, lineHeight: 16);
    return MsPressable(
      onTap: onTap,
      builder: (context, s) => Semantics(
        button: onTap != null,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (logo != null) ...[logo!, const PixelGap(12, 0)],
            MsText(name, kind: MsTextKind.lg, weight: 700, maxLines: 1),
            if (version != null) ...[
              const PixelGap(12, 0),
              Semantics(
                label: version,
                child: PixelText(version!, style: ver),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Voce di navigazione dell'header (`.ms-header__link`): etichetta in
/// grassetto alta 64 px; in hover fondo --ms-panel, la voce corrente ha la
/// barra d'accento di 6 px in basso.
class MsHeaderLink extends StatelessWidget {
  const MsHeaderLink({
    super.key,
    required this.label,
    this.current = false,
    this.onTap,
    this.icon,
    this.forceHover = false,
    this.forceFocus = false,
  });

  final String label;
  final bool current;
  final VoidCallback? onTap;

  /// Icona 16 px: riceve il colore da [IconTheme].
  final Widget? icon;
  final bool forceHover;
  final bool forceFocus;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return MsPressable(
      onTap: onTap,
      forceHover: forceHover,
      forceFocus: forceFocus,
      builder: (context, s) {
        final fg = (current || s.hovered) ? c.text : c.text2;
        return MergeSemantics(
          child: Semantics(
            button: true,
            selected: current,
            child: PixelFrame(
              minHeight: 64,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              centerY: true,
              repaintKey: (current, s.hovered, s.focused, c),
              painter: (p, w, h) {
                if (s.hovered) p.rect(0, 0, w, h, c.panel);
                if (current) {
                  p.rect(0, h - 8, w, 2, c.pxOutline);
                  p.rect(0, h - 6, w, 6, c.accent);
                }
                if (s.focused) p.outline(2, 2, w - 4, h - 4, c.focus);
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (icon != null) ...[
                    IconTheme(
                      data: IconThemeData(color: fg, size: g.d(16)),
                      child: icon!,
                    ),
                    const PixelGap(8, 0),
                  ],
                  MsText.label(label, color: fg),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Colonna con spaziatura in px di design (`.ms-stack`, gap predefinito
/// 16): i figli si allargano a tutta la larghezza come nel CSS.
///
/// `.ms-spacer` corrisponde a [Spacer] dentro una [MsRow] con `wrap: false`
/// (o una [Row]).
class MsStack extends StatelessWidget {
  const MsStack({
    super.key,
    required this.children,
    this.gap = 16,
    this.crossAxisAlignment = CrossAxisAlignment.stretch,
    this.fillLast = false,
  });

  final List<Widget> children;

  /// Distanza tra i figli in px di design.
  final double gap;
  final CrossAxisAlignment crossAxisAlignment;

  /// Con un'altezza imposta dal genitore (es. una colonna di [MsEqualRow])
  /// l'ultimo figlio si allunga fino in fondo: una colonna di pannelli
  /// finisce alla stessa altezza della colonna accanto.
  final bool fillLast;

  @override
  Widget build(BuildContext context) {
    if (fillLast) {
      return MsFillColumn(gap: gap, crossAxisAlignment: crossAxisAlignment, children: children);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: crossAxisAlignment,
      spacing: PixelScope.of(context).d(gap),
      children: children,
    );
  }
}

/// Riga con spaziatura in px di design (`.ms-row`, gap predefinito 12),
/// centrata in verticale. Con [wrap] (predefinito, come `flex-wrap: wrap`)
/// va a capo; senza, è una [Row] che accetta [Spacer] ed [Expanded].
class MsRow extends StatelessWidget {
  const MsRow({
    super.key,
    required this.children,
    this.gap = 12,
    this.wrap = true,
    this.end = false,
  });

  final List<Widget> children;
  final double gap;
  final bool wrap;

  /// Allineata a destra, anche le righe dopo un a capo (pulsanti d'azione).
  final bool end;

  @override
  Widget build(BuildContext context) {
    final d = PixelScope.of(context).d(gap);
    if (!wrap) {
      return Row(
        spacing: d,
        mainAxisAlignment: end ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: children,
      );
    }
    return Wrap(
      spacing: d,
      runSpacing: d,
      alignment: end ? WrapAlignment.end : WrapAlignment.start,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }
}
