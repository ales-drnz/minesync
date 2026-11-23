// Liste di ms.css: .ms-list (+ --flat) con righe .ms-list__row (normale,
// hover, focus, selezionata, disattivata) e .ms-table.
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../pixel/render.dart';
import '../../theme.dart';
import 'badge.dart';
import 'common.dart';
import 'text.dart';

/// Lista incassata (`.ms-list`): fondo --ms-inset, rilievo invertito,
/// contorno, padding 4 e righe separate da 2 px. [flat] toglie fondo,
/// cornice e padding (`.ms-list--flat`); [gap] cambia la distanza tra le
/// righe (px di design).
class MsList extends StatelessWidget {
  const MsList({
    super.key,
    required this.children,
    this.flat = false,
    this.gap = 2,
    this.semanticLabel,
  });

  final List<Widget> children;
  final bool flat;
  final double gap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: g.d(gap),
      children: children,
    );
    final body = flat
        ? column
        : MsUnitWidth(
            child: PixelFrame(
              padding: const EdgeInsets.all(4),
              outset: const EdgeInsets.all(2),
              repaintKey: c,
              painter: (p, w, h) {
                p.ring(0, 0, w, h, c.pxOutline);
                p.rect(0, 0, w, h, c.inset);
                p.bevel(w, h, c.pxLight, c.pxShadow, inverted: true);
              },
              child: column,
            ),
          );
    return Semantics(container: true, explicitChildNodes: true, label: semanticLabel, child: body);
  }
}

/// Riga di lista (`.ms-list__row`): alta almeno 48 px, elemento iniziale
/// ([lead]), titolo e riga secondaria ([meta]), coda ([trail]) e orario
/// ([time], in monospazio). Con [onTap] la riga intera è cliccabile.
class MsListRow extends StatelessWidget {
  const MsListRow({
    super.key,
    this.title,
    this.titleSpans,
    this.meta,
    this.lead,
    this.trail,
    this.time,
    this.titleMaxLines = 1,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.semanticLabel,
    this.forceHover = false,
    this.forceFocus = false,
  }) : assert(title != null || titleSpans != null, 'serve un titolo');

  /// Titolo (grassetto, una riga con ellissi).
  final String? title;

  /// Titolo con parti in grassetto (righe del feed: "**alice** ha preso il
  /// lock"), peso 400 e grassetto 700.
  final List<MsSpan>? titleSpans;
  final String? meta;
  final Widget? lead;
  final Widget? trail;
  final String? time;

  /// Righe del titolo prima dei puntini; null = va a capo quanto serve
  /// (feed di attività con frasi lunghe in colonne strette).
  final int? titleMaxLines;

  /// Riga selezionata: fondo --ms-sel e barra d'accento di 6 px a sinistra.
  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool forceHover;
  final bool forceFocus;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    return MsPressable(
      onTap: onTap,
      enabled: enabled,
      forceHover: forceHover,
      forceFocus: forceFocus,
      builder: (context, s) {
        final hover = s.hovered && enabled && !selected;
        final bg = selected ? c.sel : (hover ? c.panelHi : c.panel);
        final fg = !enabled ? c.text3 : (selected ? c.selText : c.text);
        final metaFg = !enabled ? c.text3 : (selected ? c.selText : c.text2);
        final titleWidget = titleSpans != null
            ? MsText.rich(titleSpans!, color: fg, maxLines: titleMaxLines)
            : MsText(title!, color: fg, weight: 600, maxLines: titleMaxLines);
        return MergeSemantics(
          child: Semantics(
            button: onTap != null,
            selected: selected,
            enabled: enabled,
            label: semanticLabel,
            child: PixelFrame(
              minHeight: 48,
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              centerY: true,
              repaintKey: (bg, selected, s.focused, c),
              painter: (p, w, h) {
                p.rect(0, 0, w, h, bg);
                p.rect(0, h - 2, w, 2, c.pxShadow);
                if (selected && enabled) p.rect(0, 0, 6, h - 2, c.accent);
                if (s.focused) p.outline(4, 4, w - 8, h - 8, c.focus);
              },
              child: Row(
                children: [
                  if (lead != null) ...[lead!, const PixelGap(16, 0)],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        titleWidget,
                        if (meta != null)
                          // più dati: etichette piatte invece dei separatori a pallino
                          meta!.contains(' · ')
                              ? Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: MsMeta.split(meta!, color: metaFg, maxLines: 1),
                                )
                              : MsText.small(meta!, color: metaFg, maxLines: 1),
                      ],
                    ),
                  ),
                  if (trail != null || time != null) const PixelGap(16, 0),
                  ?trail,
                  if (trail != null && time != null) const PixelGap(8, 0),
                  if (time != null)
                    MsText(
                      time!,
                      kind: MsTextKind.mono,
                      weight: 500,
                      color: !enabled ? c.text3 : c.text2,
                      maxLines: 1,
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Colonna di [MsTable].
@immutable
class MsTableColumn {
  const MsTableColumn(this.label, {this.width, this.flex, this.end = false});

  /// Intestazione (grassetto 14, --ms-text-2).
  final String label;

  /// Larghezza fissa in px di design.
  final double? width;

  /// Quota dello spazio libero; senza [width] né [flex] la colonna prende
  /// la larghezza del contenuto.
  final double? flex;

  /// Allinea a destra (numeri).
  final bool end;
}

/// Tabella semplice (`.ms-table`): intestazioni in etichetta pixel, celle
/// 14/20 con padding 10×12 e righe separate da una linea d'ombra di 2 px.
/// Sui telefoni va dentro [MsScrollX].
class MsTable extends StatelessWidget {
  const MsTable({super.key, required this.columns, required this.rows, this.semanticLabel});

  final List<MsTableColumn> columns;

  /// Righe di celle; ogni riga ha una cella per colonna. Per il testo usare
  /// [MsText.small] o [MsText] con `kind: MsTextKind.small`.
  final List<List<Widget>> rows;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    final line = MsBottomLine(c.pxShadow, g);
    Widget cell(Widget child, MsTableColumn col, {required bool head}) => Padding(
      padding: EdgeInsets.symmetric(horizontal: g.d(12), vertical: g.d(head ? 8 : 10)),
      child: Align(
        alignment: col.end ? Alignment.centerRight : Alignment.centerLeft,
        widthFactor: 1,
        child: child,
      ),
    );
    return Semantics(
      container: true,
      label: semanticLabel,
      child: Table(
        defaultVerticalAlignment: TableCellVerticalAlignment.middle,
        columnWidths: {
          for (var i = 0; i < columns.length; i++)
            i: switch (columns[i]) {
              MsTableColumn(width: final w?) => FixedColumnWidth(g.d(w)),
              MsTableColumn(flex: final f?) => FlexColumnWidth(f),
              _ => const IntrinsicColumnWidth(),
            },
        },
        children: [
          TableRow(
            decoration: line,
            children: [
              for (final col in columns)
                cell(
                  Semantics(
                    header: true,
                    child: MsText(
                      col.label,
                      kind: MsTextKind.labelSmall,
                      tone: MsTextTone.secondary,
                      maxLines: 1,
                    ),
                  ),
                  col,
                  head: true,
                ),
            ],
          ),
          for (final r in rows)
            TableRow(
              decoration: line,
              children: [
                for (var i = 0; i < columns.length; i++)
                  cell(i < r.length ? r[i] : const SizedBox.shrink(), columns[i], head: false),
              ],
            ),
        ],
      ),
    );
  }
}

/// Contenuto scorrevole in orizzontale (`.ms-scroll-x`), per tabelle e
/// righe larghe sugli schermi stretti.
class MsScrollX extends StatelessWidget {
  const MsScrollX({super.key, required this.child, this.controller});

  final Widget child;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) =>
      SingleChildScrollView(scrollDirection: Axis.horizontal, controller: controller, child: child);
}
