// Schede Giocatori e Mod: card con avatar generato (mai skin), ricerca e
// ordinamento, classifiche; elenco delle mod con filtri e dettaglio (sito
// solo http/https aperto in una scheda nuova, "nessun metadato"), stati
// vuoti, golden.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/pages/server/mods_tab.dart';
import 'package:minesync_hub_web/src/pages/server/players_tab.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/harness.dart';
import '../support/server_fixtures.dart';
import '../support/server_helpers.dart';

const _tall = Size(1280, 2000);

List<String> _cardOrder(WidgetTester t) => [
  for (final c in t.widgetList<PlayerCard>(find.byType(PlayerCard))) playerName(c.player),
];

Finder _row(String title) =>
    find.byWidgetPredicate((w) => w is MsListRow && w.title == title, description: 'riga $title');

void main() {
  setUpAll(loadFonts);

  group('Giocatori', () {
    testWidgets('card: avatar generato, OP, whitelist, statistiche', (t) async {
      await pumpHub(t, serverState(), location: '/server/survival/players', size: _tall);
      await settle(t);
      expect(msText('4 giocatori'), findsOneWidget);
      expect(msTextContaining('3 online, 2 OP, whitelist attiva'), findsOneWidget);
      expect(find.byType(PlayerCard), findsNWidgets(4));
      // avatar generati dal nome: nessuna immagine di rete
      expect(find.byType(Image), findsNothing);
      expect(find.byWidgetPredicate((w) => w is MsAvatar && w.name == 'bob'), findsWidgets);
      expect(msText('61 h 12 min'), findsOneWidget);
      expect(msText('1.842'), findsWidgets);
      expect(msText('412 km'), findsWidgets);
      expect(msText('800 m'), findsWidgets);
      expect(msText('in gioco ora'), findsWidgets);
      expect(msText('host'), findsWidgets);
      expect(
        find.byWidgetPredicate((w) => w is MsChip && w.label == 'Fuori whitelist'),
        findsOneWidget,
      );
    });

    testWidgets('ricerca e ordinamento', (t) async {
      await pumpHub(t, serverState(), location: '/server/survival/players', size: _tall);
      await settle(t);
      expect(_cardOrder(t), ['bob', 'carol', 'alice', 'dave']);
      await tapOn(t, find.bySemanticsLabel('Morti').first);
      expect(_cardOrder(t), ['carol', 'bob', 'alice', 'dave']);
      await t.enterText(find.byType(EditableText).first, 'CAR');
      await settle(t);
      expect(_cardOrder(t), ['carol']);
      await t.enterText(find.byType(EditableText).first, 'zzz');
      await settle(t);
      expect(msText('Nessun risultato con questi filtri.'), findsOneWidget);
    });

    testWidgets('nessun giocatore: stato vuoto', (t) async {
      await pumpHub(t, serverState(me: bob), location: '/server/creativo/players');
      await settle(t);
      expect(msText('Nessun giocatore'), findsOneWidget);
    });

    testWidgets('errore dell\'hub: avviso con Riprova', (t) async {
      final s = serverState(setup: (a) => a.playerLists.remove('survival'));
      await pumpHub(t, s, location: '/server/survival/players');
      await settle(t);
      expect(msText('Non trovato: potrebbe essere stato eliminato'), findsOneWidget);
      fakeApi(s).playerLists['survival'] = samplePlayers();
      await tapOn(t, msButton('Riprova'));
      expect(find.byType(PlayerCard), findsNWidgets(4));
    });

    testWidgets('golden: Giocatori', (t) async {
      await expectHubGolden(
        t,
        'server_players',
        serverState(me: bob),
        location: '/server/survival/players',
        size: const Size(1280, 1400),
        prepare: settle,
      );
    });

    testWidgets('golden: Giocatori, vuoto', (t) async {
      await expectHubGolden(
        t,
        'server_players_empty',
        serverState(me: bob),
        location: '/server/creativo/players',
        size: const Size(1280, 700),
        prepare: settle,
      );
    });
  });

  group('Mod', () {
    test('sito: solo http e https con un host', () {
      expect(safeHomepage('https://turbo-render.example/')?.host, 'turbo-render.example');
      expect(safeHomepage(' http://a.example/x '), isNotNull);
      expect(safeHomepage('javascript:alert(1)'), isNull);
      expect(safeHomepage('file:///etc/passwd'), isNull);
      expect(safeHomepage('https://'), isNull);
      expect(safeHomepage(null), isNull);
    });

    testWidgets('riepilogo, elenco, dettaglio con sito aperto in una scheda nuova', (t) async {
      final s = serverState(me: bob);
      await pumpHub(t, s, location: '/server/survival/mods', size: _tall);
      await settle(t);
      expect(find.bySemanticsLabel(RegExp('318 MB')), findsWidgets);
      expect(find.byType(MsListRow), findsNWidgets(4));
      // il primo per nome è selezionato
      expect(msText('Biomi Lontani'), findsNWidgets(2));
      await tapOn(t, _row('Turbo Render'));
      expect(msText('studio-pixel, ninfea'), findsOneWidget);
      expect(msText('LGPL-3.0'), findsOneWidget);
      expect(msText('#12, aggiornata in #33'), findsOneWidget);
      await tapOn(t, msButtonSem('Apri turbo-render.example in una nuova scheda'));
      expect(fakePlatform(s).opened.single.toString(), 'https://turbo-render.example/');
    });

    testWidgets('jar senza metadati e chiusura del dettaglio', (t) async {
      await pumpHub(t, serverState(), location: '/server/survival/mods', size: _tall);
      await settle(t);
      await tapOn(t, _row('server-tweak-local'));
      expect(msText('Nessun metadato'), findsOneWidget);
      expect(msText('mods/server-tweak-local.jar'), findsOneWidget);
      expect(msText('9f2c…41ab'), findsOneWidget);
      await tapOn(t, msButtonSem('Chiudi il dettaglio'));
      expect(find.byType(ModDetail), findsNothing);
    });

    testWidgets('ricerca per autore, filtri, ordinamento per dimensione', (t) async {
      await pumpHub(t, serverState(), location: '/server/survival/mods', size: _tall);
      await settle(t);
      await t.enterText(find.byType(EditableText).first, 'ninfea');
      await settle(t);
      expect(find.byType(MsListRow), findsOneWidget);
      expect(msText('1 di 4'), findsOneWidget);
      await t.enterText(find.byType(EditableText).first, '');
      await settle(t);
      await tapOn(t, find.byWidgetPredicate((w) => w is MsChip && w.label == 'Senza metadati 1'));
      expect(find.byType(MsListRow), findsOneWidget);
      await tapOn(
        t,
        find.byWidgetPredicate((w) => w is MsChip && w.label == 'Cambiate nell\'ultima versione 1'),
      );
      expect(t.widget<MsListRow>(find.byType(MsListRow)).title, 'Forziere Plus');
    });

    testWidgets('nessuna mod: stato vuoto', (t) async {
      await pumpHub(t, serverState(), location: '/server/creativo/mods');
      await settle(t);
      expect(msText('Nessuna mod'), findsOneWidget);
    });

    testWidgets('golden: Mod con dettaglio', (t) async {
      await expectHubGolden(
        t,
        'server_mods',
        serverState(),
        location: '/server/survival/mods',
        size: const Size(1280, 1000),
        prepare: (t) async {
          await settle(t);
          await t.tap(_row('Turbo Render'));
          await settle(t);
        },
      );
    });

    testWidgets('golden: Mod, vuoto', (t) async {
      await expectHubGolden(
        t,
        'server_mods_empty',
        serverState(),
        location: '/server/creativo/mods',
        size: const Size(1280, 700),
        prepare: settle,
      );
    });
  });
}
