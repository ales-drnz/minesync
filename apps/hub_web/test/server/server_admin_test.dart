// Scheda Amministrazione di un server: rinomina, valori propri o ereditati,
// esclusioni (di sistema e del profilo bloccate, proprie modificabili),
// pulizia con anteprima, eliminazione (scrivendo il nome; bloccata con un
// lock vivo), golden. Solo admin.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/pages/not_found_page.dart';
import 'package:minesync_hub_web/src/pages/overview/overview_page.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/harness.dart';
import '../support/server_fixtures.dart';
import '../support/server_helpers.dart';

const _tall = Size(1280, 2400);
const _loc = '/server/survival/admin';

/// Campo di testo con l'etichetta accessibile [label].
Finder _input(String label) => find.descendant(
  of: find.byWidgetPredicate((w) => w is MsTextInput && w.semanticLabel == label),
  matching: find.byType(EditableText),
);

Finder _seg(String label) =>
    find.byWidgetPredicate((w) => w is MsSegmented<bool> && w.semanticLabel == label);

void main() {
  setUpAll(loadFonts);

  testWidgets('membro: la scheda non esiste', (t) async {
    await pumpHub(t, serverState(me: bob), location: _loc);
    await settle(t);
    expect(find.byType(NotFoundPage), findsOneWidget);
  });

  testWidgets('rinomina', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    expect(disabled(t, msButton('Rinomina')), isTrue);
    await t.enterText(_input('Nome'), 'Survival 2');
    await settle(t);
    await tapOn(t, msButton('Rinomina'));
    expect(lastPatch(fakeApi(s), 'survival'), contains('name: Survival 2'));
    expect(toasts(t), contains('Nome cambiato in Survival 2'));
    expect(msText('Survival 2'), findsWidgets);
  });

  testWidgets('valori: eredita o personalizza, salvataggio con le sezioni', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    // la conservazione è già personalizzata (20 · 24 · 3)
    expect(msText('Globale: ultime 30, 24 h, 7 giorni'), findsOneWidget);
    expect(msText('ogni 5 min'), findsOneWidget);
    await tapOn(
      t,
      find.descendant(
        of: _seg('Salvataggio automatico: origine'),
        matching: find.bySemanticsLabel('Personalizza'),
      ),
    );
    await t.enterText(_input('Minuti tra un salvataggio e l\'altro'), '10');
    await tapOn(t, msButton('Salva'));
    final p = lastPatch(fakeApi(s), 'survival')!;
    expect(p, contains('sessions: {autosaveMinutes: 10}'));
    expect(p, contains('history: {keepLast: 20, keepHours: 24, keepDays: 3}'));
    expect(p, contains('protection: {}'));
    expect(toasts(t), contains('Salvato e attivo'));
  });

  testWidgets('valori: tornare a "Eredita" manda la sezione vuota', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(
      t,
      find.descendant(
        of: _seg('Conservazione della storia: origine'),
        matching: find.bySemanticsLabel('Eredita'),
      ),
    );
    await tapOn(t, msButton('Salva'));
    expect(lastPatch(fakeApi(s), 'survival'), contains('history: {}'));
  });

  testWidgets('valori: numero non valido o rifiutato dall\'hub', (t) async {
    final s = serverState(
      setup: (a) => a.failOn['updateSpace'] = const ApiError(
        ErrorCode.badRequest,
        'x',
        details: {'field': 'overrides.history.keepLast'},
      ),
    );
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await t.enterText(_input('Ultime versioni'), 'tanti');
    await tapOn(t, msButton('Salva'));
    expect(msText('Inserisci un numero intero'), findsOneWidget);
    expect(fakeApi(s).calls.where((c) => c.startsWith('updateSpace')), isEmpty);
    await t.enterText(_input('Ultime versioni'), '0');
    await tapOn(t, msButton('Salva'));
    expect(msText('Valore non valido: overrides.history.keepLast'), findsOneWidget);
  });

  testWidgets('esclusioni: di sistema e del profilo bloccate, proprie da aggiungere e togliere', (
    t,
  ) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    for (final p in systemExclusions) {
      expect(msText(p), findsOneWidget);
    }
    expect(find.byWidgetPredicate((w) => w is MsChip && w.label == 'di sistema'), findsNWidgets(3));
    expect(msButton('… altre 2 dal profilo Minecraft'), findsOneWidget);
    await tapOn(t, msButton('… altre 2 dal profilo Minecraft'));
    expect(msText('*.lock'), findsOneWidget);
    expect(msButtonSem('Rimuovi logs/**'), findsNothing);

    await t.enterText(_input('Nuovo pattern'), 'bluemap/**');
    await tapOn(t, msButton('Aggiungi'));
    expect(msText('Pattern già presente'), findsOneWidget);

    await t.enterText(_input('Nuovo pattern'), 'world/backups/**');
    await tapOn(t, msButton('Aggiungi'));
    expect(
      lastPatch(fakeApi(s), 'survival'),
      contains('exclusions: [bluemap/**, world/backups/**]'),
    );
    await tapOn(t, msButtonSem('Rimuovi bluemap/**'));
    expect(lastPatch(fakeApi(s), 'survival'), contains('exclusions: [world/backups/**]'));
    expect(toasts(t), contains('bluemap/** di nuovo sincronizzato'));
  });

  testWidgets('pulizia: anteprima, conferma, esito', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('eliminerebbe 21 versioni, ~3,0 GB'), findsOneWidget);
    expect(fakeApi(s).calls, contains('gcPreview survival 20'));
    await t.enterText(_input('Versioni da mantenere'), '0');
    await settle(t);
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('Inserisci un numero maggiore di 0'), findsOneWidget);
    expect(disabled(t, msButton('Pulisci Survival…')), isTrue);
    await t.enterText(_input('Versioni da mantenere'), '20');
    await t.pump(const Duration(milliseconds: 400));
    await settle(t);
    await tapOn(t, msButton('Pulisci Survival…'));
    expect(msText('Pulire Survival?'), findsOneWidget);
    await tapOn(t, find.descendant(of: find.byType(MsDialog), matching: msButton('Pulisci')));
    expect(fakeApi(s).calls, contains('gc survival 20'));
    expect(toasts(t), contains('Pulizia completata'));
    expect(toastTexts(t), contains('Eliminate 21 versioni, liberati 3,0 GB'));
  });

  testWidgets('eliminazione: bloccata con un lock vivo', (t) async {
    await pumpHub(t, serverState(), location: _loc, size: _tall);
    await settle(t);
    expect(msText('Non disponibile durante una partita'), findsOneWidget);
    expect(disabled(t, msButton('Elimina Survival…')), isTrue);
  });

  testWidgets('eliminazione: scrivendo il nome, poi la Panoramica', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/creativo/admin', size: _tall);
    await settle(t);
    await tapOn(t, msButton('Elimina Creativo…'));
    expect(msText('Eliminare Creativo?'), findsOneWidget);
    final confirm = find.descendant(
      of: find.byType(MsDialog),
      matching: msButton('Elimina Creativo'),
    );
    expect(disabled(t, confirm), isTrue);
    await t.enterText(
      find.descendant(of: find.byType(MsDialog), matching: find.byType(EditableText)),
      'Creativo',
    );
    await settle(t);
    await tapOn(t, confirm);
    expect(fakeApi(s).calls, contains('deleteSpace creativo'));
    expect(toasts(t), contains('Creativo eliminato'));
    expect(find.byType(OverviewPage), findsOneWidget);
  });

  testWidgets('eliminazione rifiutata dall\'hub: avviso', (t) async {
    final s = serverState(setup: (a) => a.failOn['deleteSpace'] = lockedError);
    await pumpHub(t, s, location: '/server/creativo/admin', size: _tall);
    await settle(t);
    await tapOn(t, msButton('Elimina Creativo…'));
    await t.enterText(
      find.descendant(of: find.byType(MsDialog), matching: find.byType(EditableText)),
      'Creativo',
    );
    await settle(t);
    await tapOn(
      t,
      find.descendant(of: find.byType(MsDialog), matching: msButton('Elimina Creativo')),
    );
    expect(toasts(t), contains('bob sta giocando su questo server'));
  });

  testWidgets('golden: Amministrazione', (t) async {
    await expectHubGolden(
      t,
      'server_admin',
      serverState(),
      location: _loc,
      size: const Size(1280, 2300),
      prepare: (t) async {
        await settle(t);
        await t.pump(const Duration(milliseconds: 400));
        await settle(t);
      },
    );
  });
}
