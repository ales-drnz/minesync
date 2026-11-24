// Contenitori di ms.css: .ms-panel (+ --raised, __head, __body, __foot),
// .ms-slot (+ --sq) e .ms-card (+ --add, --static, selezionata).
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import '../../tokens.g.dart';
import 'common.dart';
import 'layout.dart';
import 'text.dart';

/// Spaziatura interna del corpo di un pannello.
enum MsPanelPadding {
  /// `.ms-panel__body`: 20 px.
  normal,

  /// `.ms-panel__body--tight`: 12 px.
  tight,

  /// Nessuna (il contenuto gestisce i propri margini).
  none,
}

/// Pannello in rilievo (`.ms-panel`): faccia --ms-panel, rilievo di 2 px e
/// contorno con angoli smussati. [raised] non cambia più l'aspetto: tutti i
/// pannelli hanno lo stesso bordo, senza ombre diverse.
///
/// Riempie la larghezza disponibile (è un blocco), arrotondata all'unità.
/// Se il genitore impone un'altezza minima (una colonna di [MsEqualRow]) la
/// riempie:
/// il corpo resta in alto e il piede va sul bordo inferiore. Con altezza
/// libera o solo limitata (dialoghi) segue il contenuto.
class MsPanel extends StatelessWidget {
  const MsPanel({
    super.key,
    this.title,
    this.plainTitle = false,
    this.actions = const [],
    this.head,
    this.child,
    this.padding = MsPanelPadding.normal,
    this.foot = const [],
    this.raised = false,
    this.scrollBody = false,
    this.semanticLabel,
  });

  /// Titolo della testata (`.ms-panel__title`); senza titolo né [head] la
  /// testata non c'è.
  final String? title;

  /// Titolo senza quadratino d'accento (`.ms-panel__title--plain`).
  final bool plainTitle;

  /// Azioni a destra nella testata (`.ms-panel__actions`).
  final List<Widget> actions;

  /// Testata personalizzata al posto di quella con [title].
  final Widget? head;

  /// Corpo del pannello.
  final Widget? child;
  final MsPanelPadding padding;

  /// Pulsanti del piede (`.ms-panel__foot`, allineati a destra).
  final List<Widget> foot;
  final bool raised;

  /// Con un'altezza imposta (es. una colonna alta quanto la finestra) testata
  /// e piede restano fermi e il corpo scorre al suo interno.
  final bool scrollBody;

  /// Etichetta della regione per le tecnologie assistive (predefinita: il
  /// titolo).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final pad = switch (padding) {
      MsPanelPadding.normal => 16.0,
      MsPanelPadding.tight => 12.0,
      MsPanelPadding.none => 0.0,
    };
    final headWidget =
        head ??
        (title == null ? null : MsPanelHead(title: title!, plain: plainTitle, actions: actions));
    final label = semanticLabel ?? title;
    return Semantics(
      container: true,
      explicitChildNodes: true,
      label: label,
      child: MsUnitWidth(
        child: PixelFrame(
          // l'ombra del rilievo si disegna fuori dalla misura (il disegno non
          // è ritagliato): la faccia è larga come quella dei pannelli piatti
          // accanto e sotto, e i bordi restano allineati
          outset: const EdgeInsets.all(2),
          fillHeight: true,
          repaintKey: (raised, c),
          painter: (p, w, h) {
            p.ring(0, 0, w, h, c.pxOutline);
            p.rect(0, 0, w, h, c.panel);
            p.bevel(w, h, c.pxLight, c.pxShadow);
          },
          child: scrollBody
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    ?headWidget,
                    Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.all(PixelScope.of(context).d(pad)),
                        child: child,
                      ),
                    ),
                    if (foot.isNotEmpty) MsPanelFoot(children: foot),
                  ],
                )
              : MsFillColumn(
                  // solo il piede va in fondo; senza piede il corpo resta in alto
                  fill: foot.isEmpty ? MsFill.none : MsFill.pushLast,
                  children: [
                    ?headWidget,
                    if (child != null)
                      Padding(padding: EdgeInsets.all(PixelScope.of(context).d(pad)), child: child),
                    if (foot.isNotEmpty) MsPanelFoot(children: foot),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Testata di pannello (`.ms-panel__head`): alta sempre 40 px (le azioni,
/// pillole e pulsanti piccoli, sono centrate senza allungarla), faccia
/// --ms-panel-hi con luce in alto a sinistra e ombra a destra e in basso.
class MsPanelHead extends StatelessWidget {
  const MsPanelHead({
    super.key,
    required this.title,
    this.plain = false,
    this.actions = const [],
    this.leading,
  });

  final String title;
  final bool plain;
  final List<Widget> actions;

  /// Elemento prima del titolo (es. un'icona).
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    return SizedBox(
      height: PixelScope.of(context).d(40),
      child: PixelFrame(
        minHeight: 40,
        // stessi margini del corpo (16): titolo, stato e pulsanti della testa
        // stanno sulle stesse verticali del contenuto sotto
        padding: EdgeInsets.fromLTRB(leading != null ? 8 : 16, 0, 16, 0),
        centerY: true,
        fillHeight: true,
        repaintKey: c,
        painter: (p, w, h) {
          p.rect(0, 0, w, h, c.panelHi);
          p.rect(0, h - 2, w, 2, c.pxShadow);
          p.rect(w - 2, 0, 2, h, c.pxShadow);
          p.rect(0, 0, w, 2, c.pxLight);
          p.rect(0, 0, 2, h, c.pxLight);
        },
        child: Row(
          children: [
            if (leading != null) ...[MsCompact(child: leading!), const PixelGap(10, 0)],
            if (!plain) ...[
              PixelBox(
                width: 10,
                height: 10,
                repaintKey: c,
                painter: (p, w, h) => p.accentSquare(0, 0, c.accent, c.accentLo),
              ),
              const PixelGap(8, 0),
            ],
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                heightFactor: 1,
                child: Semantics(header: true, child: MsText.label(title)),
              ),
            ),
            if (actions.isNotEmpty) ...[
              const PixelGap(12, 0),
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const PixelGap(8, 0),
                MsCompact(child: actions[i]),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Piede di pannello o dialogo (`.ms-panel__foot`): filo d'ombra in alto e
/// azioni allineate a destra, a capo se non entrano.
class MsPanelFoot extends StatelessWidget {
  const MsPanelFoot({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return PixelFrame(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      repaintKey: c,
      painter: (p, w, h) => p.rect(0, 0, w, 2, c.pxShadow),
      child: Align(
        alignment: Alignment.centerRight,
        heightFactor: 1,
        child: Wrap(
          alignment: WrapAlignment.end,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: g.d(12),
          runSpacing: g.d(12),
          children: children,
        ),
      ),
    );
  }
}

/// Slot incassato (`.ms-slot`): luce e ombra invertite, padding 12 px.
/// [square] è lo slot quadrato da 56 px (`.ms-slot--sq`) che ospita un
/// contenuto di 48×48 centrato (texture, icona).
class MsSlot extends StatelessWidget {
  const MsSlot({super.key, required this.child, this.square = false, this.padding}) : _side = 56;

  /// Slot quadrato di lato [side] px: il contenuto ha un riquadro di
  /// [side] − 8 px per lato. Senza [side] prende la larghezza fissa del
  /// riquadro che lo contiene (es. `SizedBox(width: 44)`), altrimenti 56:
  /// resta sempre un quadrato.
  const MsSlot.square({super.key, required this.child, double? side})
    : _side = side,
      square = true,
      padding = null;

  final Widget child;
  final bool square;

  final double? _side;

  /// Padding in px di design (predefinito 12, quadrato 4).
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final g = PixelScope.of(context);
    if (square && _side == null) {
      return LayoutBuilder(
        builder: (context, box) => _frame(
          context,
          box.hasTightWidth && box.maxWidth.isFinite ? box.maxWidth / g.d(1) : 56,
        ),
      );
    }
    return _frame(context, _side ?? 56);
  }

  Widget _frame(BuildContext context, double side) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    return PixelFrame(
      padding: padding ?? EdgeInsets.all(square ? 4 : 12),
      minWidth: square ? side : 0,
      minHeight: square ? side : 0,
      centerX: square,
      centerY: square,
      repaintKey: c,
      painter: (p, w, h) {
        p.rect(0, 0, w, h, c.inset);
        p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
      },
      child: square
          ? SizedBox.square(
              dimension: g.d(side - 8),
              child: Center(child: child),
            )
          : child,
    );
  }
}

/// Variante di card.
enum MsCardKind {
  /// Card cliccabile (`.ms-card`): blocco estruso con lato di 4 px, sale di
  /// 2 px in hover e scende premuta.
  normal,

  /// Card statica (`.ms-card--static`): stesso aspetto, nessuna reazione.
  static,

  /// Card "aggiungi" (`.ms-card--add`): tratteggio interno, contenuto
  /// centrato, alta almeno 120 px.
  add,
}

/// Card (`.ms-card`). Riempie la larghezza disponibile.
///
/// Gli stati `force*` riproducono `.is-hover`, `.is-pressed` e il focus per
/// mockup e golden.
class MsCard extends StatelessWidget {
  const MsCard({
    super.key,
    required this.child,
    this.onTap,
    this.selected = false,
    this.kind = MsCardKind.normal,
    this.semanticLabel,
    this.forceHover = false,
    this.forcePressed = false,
    this.forceFocus = false,
  }) : addLabel = null,
       addIcon = null;

  /// Card "aggiungi" con icona facoltativa ed etichetta in grassetto.
  const MsCard.add({
    super.key,
    required String label,
    Widget? icon,
    this.onTap,
    this.semanticLabel,
    this.forceHover = false,
    this.forcePressed = false,
    this.forceFocus = false,
  }) : child = null,
       addLabel = label,
       addIcon = icon,
       selected = false,
       kind = MsCardKind.add;

  final Widget? child;
  final VoidCallback? onTap;

  /// Card corrente (`.is-selected`, `aria-current`): contorno e lato in
  /// --ms-accent.
  final bool selected;
  final MsCardKind kind;
  final String? semanticLabel;
  final String? addLabel;
  final Widget? addIcon;
  final bool forceHover;
  final bool forcePressed;
  final bool forceFocus;

  @override
  Widget build(BuildContext context) {
    final interactive = kind != MsCardKind.static;
    return MsUnitWidth(
      child: MsPressable(
        onTap: interactive ? onTap : null,
        forceHover: interactive && forceHover,
        forcePressed: interactive && forcePressed,
        forceFocus: forceFocus,
        builder: (context, s) {
          final inner = kind == MsCardKind.add ? _addFrame(context, s) : _frame(context, s);
          return MergeSemantics(
            child: Semantics(
              button: interactive && onTap != null,
              selected: selected,
              label: semanticLabel ?? addLabel,
              child: inner,
            ),
          );
        },
      ),
    );
  }

  Widget _frame(BuildContext context, MsPressState s) {
    final c = MsTheme.colorsOf(context);
    final hover = kind == MsCardKind.normal && s.hovered;
    final pressed = kind == MsCardKind.normal && s.pressed;
    final target = pressed ? 2.0 : (hover ? -2.0 : 0.0);
    final face = hover ? c.panelHi : c.panel;
    final edge = selected ? c.accent : c.pxOutline;
    final side = selected ? c.accentLo : c.pxShadow;
    return MsPixelShift(
      target: target,
      duration: MsDuration.d2,
      builder: (context, shift) => PixelFrame(
        padding: const EdgeInsets.all(16),
        outset: const EdgeInsets.fromLTRB(2, 2, 2, 6),
        // in una riga di card alte uguali riempie l'altezza
        fillHeight: true,
        childShiftPhys: shift,
        repaintKey: (shift, face, edge, s.focused, c),
        painter: (p0, w, h) {
          final p = p0.shiftPhys(0, shift);
          // lato inferiore di 4 px con contorno e angoli smussati
          p.rect(0, h, w, 4, side);
          p.rect(-2, h, 2, 4, edge);
          p.rect(w, h, 2, 4, edge);
          p.rect(0, h + 4, w, 2, edge);
          p.ring(0, 0, w, h, edge);
          p.rect(0, 0, w, h, face);
          p.bevel(w, h, c.pxLight, c.pxShadow);
          if (s.focused) p.outline(-2, -2, w + 4, h + 4, c.focus);
        },
        child: child,
      ),
    );
  }

  Widget _addFrame(BuildContext context, MsPressState s) {
    final c = MsTheme.colorsOf(context);
    final hover = s.hovered;
    final fg = hover ? c.text : c.text2;
    final g = PixelScope.of(context);
    return PixelFrame(
      padding: const EdgeInsets.all(16),
      outset: const EdgeInsets.fromLTRB(2, 2, 2, 6),
      minHeight: 120,
      // nella riga di card alte uguali arriva al fondo come le vicine
      fillHeight: true,
      centerX: true,
      centerY: true,
      repaintKey: (hover, s.focused, c),
      painter: (p, w, h) {
        if (hover) p.rect(0, 0, w, h, c.panel);
        p.dashedOutline(2, 2, w - 4, h - 4, c.text3);
        if (s.focused) p.outline(-2, -2, w + 4, h + 4, c.focus);
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (addIcon != null) ...[
            IconTheme(
              data: IconThemeData(color: fg, size: g.d(16)),
              child: addIcon!,
            ),
            const PixelGap(12, 0),
          ],
          MsText.label(addLabel ?? '', color: fg),
        ],
      ),
    );
  }
}
