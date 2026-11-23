// Storia di un server: elenco con filtro e ricerca, dettaglio con le
// differenze, ripristino solo per admin e con conferma.
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:ms_ui/ms_ui.dart';

import 'home_test.dart' show homeSpaces;
import 'support/app_harness.dart';
import 'support/finders.dart';

const _diff56 = GenerationDiff(
  n: 56,
  parent: 55,
  files: 1204,
  size: 900 << 20,
  added: [('world/region/r.1.0.mca', 9800 << 10), ('world/data/map_3.dat', 4 << 10)],
  changed: [
    ('world/region/r.0.0.mca', 7 << 20),
    ('world/region/r.-1.0.mca', 6 << 20),
    ('world/level.dat', 4 << 10),
    ('world/playerdata/a1.dat', 12 << 10),
    ('world/stats/a1.json', 3 << 10),
    ('world/region/r.2.3.mca', 2 << 20),
    ('world/region/r.0.-1.mca', 7 << 20),
    ('world/advancements/a1.json', 2 << 10),
    ('world/data/raids.dat', 1 << 10),
  ],
  removed: [('world/data/old.dat', 1 << 10)],
);

AppState historyState({bool admin = true}) => testState(
  setup: (s) {
    s.debugSet(
      spaces: homeSpaces(),
      hub: sampleHub(admin: admin),
      route: const HistoryRoute('creativo'),
    );
    s
        .spaceState('creativo')
        .debugSet(
          history: [
            sampleGen(57, author: 'carol'),
            sampleGen(56),
            sampleGen(55, author: 'carol'),
            sampleGen(54, author: 'alice'),
          ],
          historyEnd: false,
          diffs: {
            56: _diff56,
            57: const GenerationDiff(
              n: 57,
              parent: 56,
              files: 1205,
              size: 900 << 20,
              added: [],
              changed: [('world/level.dat', 4 << 10)],
              removed: [],
            ),
          },
        );
  },
);

void main() {
  setUpAll(loadFonts);

  testWidgets('la versione più nuova è scelta; frecce e clic cambiano versione', (t) async {
    await pumpApp(t, historyState());
    expect(msText('Storia di Creativo'), findsOneWidget);
    expect(msText('Differenze con la #56'), findsNothing);
    // la versione attuale non offre il ripristino
    expect(msButton('Ripristina #57…'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(msButton('Ripristina #56…'), findsOneWidget);
    expect(msText('world/region/r.0.0.mca'), findsOneWidget);
    // fino a 12 file l'elenco è intero, senza «e altri N file»
    expect(msTextContaining('e altri'), findsNothing);
    // il filtro dei file è un selettore a segmenti
    final dynamic seg = t.widget(
      find.byWidgetPredicate(
        (w) => w is MsSegmented && w.segments.first.label.startsWith('Aggiunti'),
      ),
    );
    seg.onChanged(seg.segments.first.value);
    await t.pump();
    expect(msText('world/region/r.1.0.mca'), findsOneWidget);
  });

  testWidgets('ricerca per autore', (t) async {
    await pumpApp(t, historyState());
    await t.enterText(find.byType(EditableText), 'alice');
    await t.pump();
    expect(msButton('Ripristina #54…'), findsOneWidget);
  });

  testWidgets('ripristino: la testa non si ripristina, le altre chiedono conferma', (t) async {
    await pumpApp(t, historyState());
    expect(msButton('Ripristina #57…'), findsNothing);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await t.tap(msButton('Ripristina #56…'));
    await t.pump(const Duration(seconds: 1));
    expect(msText('Ripristinare la #56?'), findsOneWidget);
    expect(msButton('Ripristina come #58'), findsOneWidget);
    await t.tap(msButton('Annulla'));
    await t.pump(const Duration(seconds: 1));
    expect(msText('Ripristinare la #56?'), findsNothing);
  });

  testWidgets('chi non è admin non può ripristinare', (t) async {
    await pumpApp(t, historyState(admin: false));
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(msButton('Ripristina #56…'), findsNothing);
  });

  testWidgets('storia: golden', (t) async {
    final s = historyState();
    await pumpApp(t, s);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await expectAppGolden(t, 'history', s, size: const Size(1280, 1180));
  });

  testWidgets('conferma di ripristino: golden', (t) async {
    final s = historyState();
    await pumpApp(t, s);
    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    await t.tap(msButton('Ripristina #56…'));
    await t.pump(const Duration(seconds: 1));
    await expectAppGolden(t, 'history_restore', s, size: const Size(1280, 1180), dprs: [1.0]);
  });
}
