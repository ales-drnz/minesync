// Righe di impostazioni come nelle app di sistema: icona, titolo con la
// descrizione sotto e il controllo (interruttore, barra, pulsante) tutto a
// destra; MsSettingList le separa con un divisore.
import 'package:flutter/widgets.dart';

import '../../pixel/grid.dart';
import '../../theme.dart';
import 'header.dart';
import 'text.dart';

/// Una riga di impostazione.
///
/// Al più due righe di testo a sinistra: [title] e, subito sotto,
/// [description] in grigio, a interlinea stretta. [icon] (24 px, colore del
/// testo secondario) è centrata su titolo e descrizione; [indent] lascia
/// vuota la sua colonna. [value] è il
/// valore attuale (una cartella, una versione, "6 GB"): sta a destra, prima
/// del [control], e si accorcia con i puntini se lo spazio non basta. Sotto
/// i 520 px di larghezza valore e controllo vanno sotto il testo.
class MsSettingRow extends StatelessWidget {
  const MsSettingRow({
    super.key,
    required this.title,
    required this.control,
    this.icon,
    this.indent = false,
    this.value,
    this.description,
    this.edgeTop = false,
    this.edgeBottom = false,
  });

  /// Prima o ultima riga di [MsSettingList]: niente spazio verso il bordo,
  /// lo dà già il pannello (16), così sopra e sotto il controllo c'è lo
  /// stesso spazio in ogni riga.
  final bool edgeTop;
  final bool edgeBottom;

  final String title;
  final Widget control;
  final Widget? icon;

  /// Lascia vuota la colonna dell'icona (riga che continua la precedente).
  final bool indent;
  final Widget? value;
  final String? description;

  @override
  Widget build(BuildContext context) {
    final c = MsTheme.colorsOf(context);
    final g = PixelScope.of(context);
    // interlinea stretta: titolo 20 e descrizione 18, senza spazio tra loro
    final text = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MsText(title, weight: 700, lineHeight: 20, maxLines: 1),
        if (description != null)
          MsText.small(description!, tone: MsTextTone.secondary, lineHeight: 18),
      ],
    );
    final trail = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value != null) ...[
          Flexible(
            child: DefaultTextStyle.merge(
              style: TextStyle(color: c.text2),
              child: value!,
            ),
          ),
          SizedBox(width: g.d(16)),
        ],
        control,
      ],
    );
    final lead = icon != null || indent
        ? [
            SizedBox(
              width: g.d(24),
              child: icon == null
                  ? null
                  : IconTheme(
                      data: IconThemeData(color: c.text2, size: g.d(24)),
                      child: icon!,
                    ),
            ),
            SizedBox(width: g.d(16)),
          ]
        : const <Widget>[];
    return Padding(
      padding: EdgeInsets.only(top: edgeTop ? 0 : g.d(16), bottom: edgeBottom ? 0 : g.d(16)),
      child: LayoutBuilder(
        builder: (context, box) {
          if (box.maxWidth < g.d(520)) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ...lead,
                Expanded(
                  child: MsStack(
                    gap: 10,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [text, trail],
                  ),
                ),
              ],
            );
          }
          return Row(
            children: [
              ...lead,
              Expanded(child: text),
              SizedBox(width: g.d(24)),
              // il valore a destra prende al più metà riga
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: box.maxWidth / 2),
                child: trail,
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Righe di impostazione separate da [MsDivider].
class MsSettingList extends StatelessWidget {
  const MsSettingList({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0) const MsDivider(),
        _edges(children[i], top: i == 0, bottom: i == children.length - 1),
      ],
    ],
  );
}

/// La riga [w] senza spazio verso i bordi della lista ([top], [bottom]).
Widget _edges(Widget w, {required bool top, required bool bottom}) {
  if (w is! MsSettingRow || (!top && !bottom)) return w;
  return MsSettingRow(
    key: w.key,
    title: w.title,
    control: w.control,
    icon: w.icon,
    indent: w.indent,
    value: w.value,
    description: w.description,
    edgeTop: top,
    edgeBottom: bottom,
  );
}
