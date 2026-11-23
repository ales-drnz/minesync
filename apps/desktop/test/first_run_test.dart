// Primo avvio: benvenuto, indirizzo non valido, hub che non risponde o non
// riconosce il PC, hub che risponde (niente salvato prima di "Inizia").
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'support/app_harness.dart';
import 'support/finders.dart';

AppState firstRunState() => testState(
  setup: (s) => s.debugSet(connection: Connection.none, route: const FirstRunRoute()),
);

void main() {
  setUpAll(loadFonts);

  testWidgets('indirizzo non valido', (t) async {
    await pumpApp(t, firstRunState());
    expect(msText('Benvenuto'), findsOneWidget);
    await t.tap(msButton('Connetti'));
    await t.pump();
    expect(msTextContaining('Indirizzo non valido'), findsOneWidget);
  });

  testWidgets('hub che non risponde: errore con cosa fare, niente salvato', (t) async {
    final s = firstRunState()
      ..debugProbeHub = (_) async => throw const HubUnreachable('connessione rifiutata');
    await pumpApp(t, s);
    await t.enterText(find.byType(EditableText), '192.0.2.10:8084');
    await t.tap(msButton('Connetti'));
    await t.pump();
    expect(msText('Hub non raggiungibile'), findsOneWidget);
    expect(msText('Cosa fare'), findsOneWidget);
    expect(s.config.hub, isNull);
    await t.tap(msButton('Cambia indirizzo'));
    await t.pump();
    expect(msText('Benvenuto'), findsOneWidget);
  });

  testWidgets('l\'hub non riconosce il PC: non sei nella rete ZeroTier', (t) async {
    final s = firstRunState()
      ..debugProbeHub = (_) async =>
          throw const ApiError(ErrorCode.unauthenticated, 'unknown address');
    await pumpApp(t, s);
    await t.enterText(find.byType(EditableText), '192.0.2.10');
    await t.tap(msButton('Connetti'));
    await t.pump();
    expect(msText('PC non presente nella rete ZeroTier'), findsOneWidget);
  });

  testWidgets('connesso: ciao, server che aspettano, niente salvato prima di Inizia', (t) async {
    final s = firstRunState()..debugProbeHub = (_) async => (sampleHub(), sampleSpaces());
    await pumpApp(t, s);
    await t.enterText(find.byType(EditableText), '192.0.2.10:8084');
    await t.tap(msButton('Connetti'));
    await t.pump();
    expect(msText('Ciao, alice'), findsOneWidget);
    expect(msText('3 server disponibili'), findsOneWidget);
    expect(msButton('Inizia'), findsOneWidget);
    expect(s.config.hub, isNull);
  });

  testWidgets('primo avvio: golden', (t) async {
    await expectAppGolden(t, 'first_run', firstRunState());
  });

  testWidgets('primo avvio, errore: golden', (t) async {
    final s = firstRunState()
      ..debugProbeHub = (_) async =>
          throw const ApiError(ErrorCode.unauthenticated, 'unknown address');
    await pumpApp(t, s);
    await t.enterText(find.byType(EditableText), '192.0.2.10:8084');
    await t.tap(msButton('Connetti'));
    await t.pump();
    await expectAppGolden(t, 'first_run_error', s, dprs: [1.0]);
  });

  testWidgets('primo avvio, connesso: golden', (t) async {
    final s = firstRunState()..debugProbeHub = (_) async => (sampleHub(), sampleSpaces());
    await pumpApp(t, s);
    await t.enterText(find.byType(EditableText), '192.0.2.10:8084');
    await t.tap(msButton('Connetti'));
    await t.pump();
    await expectAppGolden(t, 'first_run_connected', s);
  });
}
