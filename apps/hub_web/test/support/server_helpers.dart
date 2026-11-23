// Aiuti per i test della pagina Server: tocchi su elementi fuori schermo,
// pulsanti per etichetta accessibile, testo delle notifiche.
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_ui/ms_ui.dart';

import 'harness.dart';

/// Pulsante con l'etichetta accessibile [label] (icone, "Copia …").
Finder msButtonSem(String label) => find.byWidgetPredicate(
  (w) => w is MsButton && w.semanticLabel == label,
  description: 'pulsante [$label]',
);

/// Porta [f] nella vista, lo tocca e lascia finire le animazioni.
Future<void> tapOn(WidgetTester t, Finder f) async {
  await t.ensureVisible(f.first);
  await t.pump();
  await t.tap(f.first);
  await settle(t);
}

/// Il pulsante [f] è disattivato.
bool disabled(WidgetTester t, Finder f) => t.widget<MsButton>(f.first).onPressed == null;

/// Titoli delle notifiche mostrate.
List<String> toasts(WidgetTester t) => [
  for (final w in t.widgetList<MsToast>(find.byType(MsToast))) w.title,
];

/// Testi delle notifiche mostrate (sottotitoli).
List<String?> toastTexts(WidgetTester t) => [
  for (final w in t.widgetList<MsToast>(find.byType(MsToast))) w.text,
];
