// Panoramica: riepilogo, card per stato del lock, feed Attività con filtri
// e pagine precedenti, "Nuovo server" solo per gli admin, golden.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/pages/overview/new_server_dialog.dart';
import 'package:minesync_hub_web/src/pages/server/server_page.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/harness.dart';

void main() {
  setUpAll(loadFonts);

  testWidgets('riepilogo: server, aperti ora, giocatori ora, disco', (t) async {
    await pumpHub(t, testState());
    expect(find.bySemanticsLabel('3 Server'), findsOneWidget);
    expect(find.bySemanticsLabel('1 Aperti ora'), findsOneWidget);
    expect(find.bySemanticsLabel('3 Giocatori ora'), findsOneWidget);
    expect(msText('bob, carol e alice'), findsWidgets);
    expect(msText('liberi 1,2 TB su 2,0 TB'), findsOneWidget);
  });

  testWidgets('card: in gioco con durata, libero con ultimo salvataggio, stale', (t) async {
    await pumpHub(t, testState());
    expect(msText('Survival'), findsWidgets);
    expect(msText('#41'), findsNothing);
    expect(msText('42 mod'), findsOneWidget);
    expect(msText('3 online'), findsOneWidget);
    // aperto alle 16:46, ora sono le 18:00
    expect(msTextContaining('1 h 14 min, ultimo salvataggio 4 min fa'), findsOneWidget);
    expect(msText('Ultimo salvataggio'), findsOneWidget);
    expect(msText('ieri 22:47'), findsOneWidget);
    expect(msText('31 GB'), findsOneWidget);
    expect(msTextContaining('Nessun segnale dal PC di carol da 3 min'), findsOneWidget);
    expect(msText('NeoForge'), findsOneWidget);
    expect(msText('214 mod'), findsOneWidget);
  });

  testWidgets('la card porta alla pagina del server', (t) async {
    await pumpHub(t, testState());
    await t.tap(find.byWidgetPredicate((w) => w is MsCard && w.semanticLabel == 'Apri Creativo'));
    await settle(t);
    expect(find.byWidgetPredicate((w) => w is ServerPage && w.id == 'creativo'), findsOneWidget);
    expect(documentTitle(t), 'Creativo: Panoramica (Hub di casa)');
  });

  testWidgets('attività: badge per tipo, frasi, filtri', (t) async {
    await pumpHub(t, testState());
    expect(
      find.byWidgetPredicate((w) => w is MsBadge && w.kind == MsBadgeKind.push),
      findsOneWidget,
    );
    expect(msText('bob ha salvato sull\'hub'), findsOneWidget);
    expect(msText('autosave'), findsOneWidget);
    expect(msText('bob ha ripristinato la versione 37'), findsOneWidget);
    expect(msText('carol ha chiuso il server dopo 2 h 05 min'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Salvataggi'));
    await t.pump();
    expect(msText('carol ha chiuso il server dopo 2 h 05 min'), findsNothing);
    expect(msText('bob ha salvato sull\'hub'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Admin').last);
    await t.pump();
    expect(msTextContaining('ha cambiato le impostazioni: Sessioni di gioco'), findsOneWidget);
  });

  testWidgets('attività: un evento dal vivo compare in cima', (t) async {
    final s = testState();
    await pumpHub(t, s);
    s.debugSet(
      events: [
        ...s.events.reversed,
        HubEvent(
          seq: 9,
          ts: at(17, 59),
          type: EventType.memberRole,
          actor: 'alice',
          data: const {'memberId': 'b2b2b2b2b2', 'member': 'bob', 'role': 'admin'},
        ),
      ],
    );
    await t.pump();
    expect(msText('alice ha reso admin bob'), findsOneWidget);
  });

  testWidgets('"Mostra le precedenti" chiede all\'hub la pagina con before', (t) async {
    final older = [
      for (var i = 1; i <= 30; i++)
        HubEvent(
          seq: i,
          ts: at(10, i),
          type: EventType.push,
          space: 'survival',
          actor: 'p$i',
          data: {'n': i, 'kind': 'push'},
        ),
    ];
    final api = FakeHubApi(events: older);
    final s = testState(
      api: api,
      setup: (s) => s.debugSet(events: older.sublist(20), eventsMore: true),
    );
    await pumpHub(t, s, size: const Size(1280, 1600));
    expect(msText('p30 ha salvato sull\'hub'), findsOneWidget);
    expect(msText('p22 ha salvato sull\'hub'), findsNothing);
    await t.tap(find.bySemanticsLabel('Mostra le precedenti'));
    await t.pump();
    expect(msText('p22 ha salvato sull\'hub'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Mostra le precedenti'));
    await t.pump();
    await t.pump();
    expect(api.calls, contains('events after=null before=21'));
    expect(s.events.length, 30);
  });

  testWidgets('admin: "Nuovo server" crea e porta alla pagina del server', (t) async {
    final s = testState();
    await pumpHub(t, s);
    await t.tap(find.bySemanticsLabel('Nuovo server').first);
    await settle(t);
    expect(find.byType(NewServerDialog), findsOneWidget);
    await t.enterText(find.byType(EditableText), 'Pianura Nuova');
    await t.pump();
    expect(msText('13/40'), findsOneWidget);
    await t.tap(msButton('Crea'));
    await settle(t);
    expect(fakeApi(s).calls, contains('createSpace Pianura Nuova'));
    expect(
      find.byWidgetPredicate((w) => w is ServerPage && w.id == 'pianura-nuova'),
      findsOneWidget,
    );
  });

  testWidgets('membro: niente "Nuovo server"', (t) async {
    await pumpHub(t, testState(me: bob));
    expect(msButton('Nuovo server'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is MsCard && w.kind == MsCardKind.add), findsNothing);
  });

  testWidgets('disco quasi pieno: avviso con la soglia', (t) async {
    await pumpHub(t, testState(api: FakeHubApi(hub: sampleHub(lowDisk: true))));
    expect(msText('Disco dell\'hub quasi pieno'), findsOneWidget);
  });

  testWidgets('golden: admin', (t) async {
    await expectHubGolden(
      t,
      'overview_admin',
      testState(setup: (s) => s.setTheme(ThemeChoice.dark)),
      size: const Size(1280, 1100),
    );
  });

  testWidgets('golden: membro, tema chiaro, disco quasi pieno', (t) async {
    final s = testState(
      api: FakeHubApi(hub: sampleHub(me: bob, lowDisk: true)),
      setup: (s) => s.setTheme(ThemeChoice.light),
    );
    await expectHubGolden(t, 'overview_member', s, size: const Size(1280, 1200));
  });

  testWidgets('golden: nessun server', (t) async {
    final s = testState(
      api: FakeHubApi(spaces: const [], events: const []),
    );
    await expectHubGolden(t, 'overview_empty', s);
  });

  testWidgets('golden: hub offline', (t) async {
    final s = testState(
      setup: (s) => s.debugSet(connection: HubConnection.offline, offlineSince: testNow),
    );
    await expectHubGolden(t, 'overview_offline', s, size: const Size(1280, 1100));
  });

  testWidgets('golden: telefono', (t) async {
    await expectHubGolden(t, 'overview_phone', testState(), size: const Size(375, 1600));
  });
}
