// Cornice dell'app: barra laterale, navigazione, stato della connessione.
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/screens/screens.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/app_harness.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('la barra laterale elenca i server e porta alle loro schermate', (t) async {
    final s = testState();
    await pumpApp(t, s);
    expect(find.bySemanticsLabel(RegExp('^Survival')), findsWidgets);
    await t.tap(find.bySemanticsLabel(RegExp('^Creativo')).first);
    await t.pump();
    expect(s.route, const ServerRoute('creativo'));
    expect(find.byType(ServerScreen), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Impostazioni').first);
    await t.pump();
    expect(find.byType(SettingsScreen), findsOneWidget);
  });

  testWidgets('primo avvio: niente barra laterale', (t) async {
    final s = testState(setup: (s) => s.debugSet(route: const FirstRunRoute()));
    await pumpApp(t, s);
    expect(find.byType(FirstRunScreen), findsOneWidget);
    expect(find.byType(MsSidebar), findsNothing);
  });

  testWidgets('lingua inglese dalle preferenze', (t) async {
    final s = testState();
    s.config.lang = 'en';
    await pumpApp(t, s);
    expect(find.bySemanticsLabel('Settings'), findsWidgets);
  });

  testWidgets('cornice: golden', (t) async {
    await expectAppGolden(t, 'shell', testState());
  });
}
