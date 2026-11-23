// Scheda Storia: righe (HEAD, ripristino di, file danneggiati, +~−), zip per
// tutti, differenze con la precedente e file danneggiati, ripristino ed
// eliminazione (admin, conferme, bloccati da un lock vivo), "Ripristina
// integro", ricerca e filtri, pagine precedenti, stato vuoto, golden.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/harness.dart';
import '../support/server_fixtures.dart';
import '../support/server_helpers.dart';

const _tall = Size(1280, 2000);
const _loc = '/server/survival/history';

/// Survival senza lock: si può ripristinare.
void _free(FakeHubApi a) => a.spaceList = [
  for (final sp in a.spaceList)
    sp.id != 'survival'
        ? sp
        : SpaceSummary(
            id: sp.id,
            name: sp.name,
            profile: sp.profile,
            createdAt: sp.createdAt,
            head: sp.head,
            lock: null,
            world: sp.world,
          ),
];

Finder _dialogButton(String label) =>
    find.descendant(of: find.byType(MsDialog), matching: msButton(label));

void main() {
  setUpAll(loadFonts);

  testWidgets('righe: HEAD, ripristino di, danneggiati, autore e dimensione, zip', (t) async {
    final s = serverState(me: bob);
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    expect(msText('41 versioni'), findsOneWidget);
    expect(msTextContaining('18 GB in totale, 6,0 GB occupati sull\'hub'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is MsChip && w.label == 'HEAD'), findsOneWidget);
    expect(
      find.byWidgetPredicate((w) => w is MsChip && w.label == 'ripristino di #37'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((w) => w is MsPill && w.label == '2 region danneggiati'),
      findsOneWidget,
    );
    expect(msText('Prima del drago'), findsOneWidget);
    expect(msText('oggi 17:56'), findsWidgets);
    expect(msText('1.284 file'), findsWidgets);
    expect(find.bySemanticsLabel('0 aggiunti, 48 modificati, 3 rimossi'), findsOneWidget);
    // un membro scarica ma non ripristina né elimina
    expect(msButton('Ripristina'), findsNothing);
    expect(msButtonSem('Elimina la versione #39'), findsNothing);
    await tapOn(t, msButtonSem('Scarica lo zip di #39'));
    expect(
      fakePlatform(s).downloads.single.toString(),
      'http://192.0.2.1/api/v1/spaces/survival/generations/39/zip',
    );
  });

  testWidgets('admin: niente ripristino né eliminazione sulla HEAD', (t) async {
    await pumpHub(t, serverState(), location: _loc, size: _tall);
    await settle(t);
    expect(msButtonSem('Ripristina #41'), findsNothing);
    expect(msButtonSem('Elimina la versione #41'), findsNothing);
    expect(msButtonSem('Ripristina #40'), findsOneWidget);
    expect(msButtonSem('Elimina la versione #40'), findsOneWidget);
  });

  testWidgets('differenze: gruppi con totali, al più 120 righe, file danneggiati', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(t, msButtonSem('Mostra le differenze di #40'));
    expect(fakeApi(s).calls, contains('diff survival 40'));
    expect(msText('Differenze con #39'), findsOneWidget);
    expect(msText('fino a 120 file per gruppo'), findsOneWidget);
    expect(msText('Nessun file aggiunto'), findsOneWidget);
    expect(msText('mostrati 2 di 48'), findsOneWidget);
    expect(msText('world/data/raids.dat'), findsOneWidget);
    expect(msText('2 file danneggiati in questa versione'), findsOneWidget);
    expect(msText('3 su 1.024'), findsOneWidget);
    // senza una generazione integra il pulsante è spento
    expect(disabled(t, msButtonSem('Ripristina world/region/r.-1.2.mca da #39')), isFalse);
    expect(disabled(t, msButtonSem('Ripristina integro')), isTrue);
    await tapOn(t, msButtonSem('Nascondi le differenze di #40'));
    expect(msText('Differenze con #39'), findsNothing);
  });

  testWidgets('membro: i file danneggiati chiedono un admin', (t) async {
    await pumpHub(
      t,
      serverState(me: bob),
      location: _loc,
      size: _tall,
    );
    await settle(t);
    await tapOn(t, msButtonSem('Mostra le differenze di #40'));
    expect(msText('richiede un admin'), findsNWidgets(2));
    expect(msButton('Ripristina integro'), findsNothing);
  });

  testWidgets('ripristino: bloccato mentre qualcuno gioca', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(t, msButtonSem('Ripristina #39'));
    expect(msText('Ripristinare #39?'), findsOneWidget);
    expect(msText('Operazione non disponibile'), findsOneWidget);
    expect(disabled(t, _dialogButton('Ripristina')), isTrue);
    await tapOn(t, _dialogButton('Annulla'));
    expect(fakeApi(s).calls.where((c) => c.startsWith('restore ')), isEmpty);
  });

  testWidgets('ripristino: crea una generazione nuova', (t) async {
    final s = serverState(setup: _free);
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(t, msButtonSem('Ripristina #37'));
    expect(msTextContaining('diventa la nuova versione #42'), findsOneWidget);
    expect(msTextContaining('#38–#41 restano nella storia'), findsOneWidget);
    await tapOn(t, _dialogButton('Ripristina'));
    expect(fakeApi(s).calls, contains('restore survival 37'));
    expect(toasts(t), contains('#37 ripristinata come #42'));
    // la storia si rilegge
    expect(fakeApi(s).calls.where((c) => c.startsWith('generations survival')).length, 2);
  });

  testWidgets('ripristino rifiutato dall\'hub: avviso con chi gioca', (t) async {
    final s = serverState(
      setup: (a) {
        _free(a);
        a.failOn['restore'] = lockedError;
      },
    );
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(t, msButtonSem('Ripristina #39'));
    await tapOn(t, _dialogButton('Ripristina'));
    expect(toasts(t), contains('bob sta giocando su questo server'));
  });

  testWidgets('eliminazione: irreversibile, mostra quanto libera', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(t, msButtonSem('Elimina la versione #39'));
    expect(msText('Eliminare #39?'), findsOneWidget);
    expect(msTextContaining('si liberano circa 120 MB'), findsOneWidget);
    expect(fakeApi(s).calls, contains('freed survival 39'));
    await tapOn(t, _dialogButton('Elimina #39'));
    expect(fakeApi(s).calls, contains('deleteGeneration survival 39'));
    expect(toasts(t), contains('#39 eliminata'));
    expect(toastTexts(t), contains('Liberati 120 MB'));
  });

  testWidgets('"Ripristina integro" riprende un solo file', (t) async {
    final s = serverState(setup: _free);
    await pumpHub(t, s, location: _loc, size: _tall);
    await settle(t);
    await tapOn(t, msButtonSem('Mostra le differenze di #40'));
    await tapOn(t, msButtonSem('Ripristina world/region/r.-1.2.mca da #39'));
    expect(msText('Ripristinare il file integro?'), findsOneWidget);
    await tapOn(t, _dialogButton('Ripristina il file'));
    expect(fakeApi(s).calls, contains('restoreFile survival world/region/r.-1.2.mca 39'));
    expect(toasts(t), contains('world/region/r.-1.2.mca ripristinato'));
  });

  testWidgets('ricerca per #N e filtri', (t) async {
    await pumpHub(t, serverState(), location: _loc, size: _tall);
    await settle(t);
    await t.enterText(find.byType(EditableText).first, '#37');
    await settle(t);
    expect(msText('Prima del drago'), findsOneWidget);
    expect(msText('Autosave'), findsNothing);
    await t.enterText(find.byType(EditableText).first, '');
    await settle(t);
    await tapOn(t, find.bySemanticsLabel('Ripristini'));
    expect(msText('Ripristino'), findsOneWidget);
    expect(msText('Prima del drago'), findsNothing);
    await tapOn(t, find.bySemanticsLabel('Con problemi'));
    expect(find.byWidgetPredicate((w) => w is MsLevel && w.text == '#40'), findsOneWidget);
  });

  testWidgets('pagine precedenti con before', (t) async {
    final s = serverState(
      setup: (a) =>
          a.history['survival'] = [for (var n = 41; n >= 1; n--) sampleGen(n, ts: at(10, 0))],
    );
    await pumpHub(t, s, location: _loc, size: const Size(1280, 6000));
    await settle(t);
    expect(find.byWidgetPredicate((w) => w is MsLevel && w.text == '#22'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is MsLevel && w.text == '#21'), findsNothing);
    await tapOn(t, msButton('Carica le precedenti (21)'));
    expect(fakeApi(s).calls, contains('generations survival 22'));
    expect(find.byWidgetPredicate((w) => w is MsLevel && w.text == '#21'), findsOneWidget);
  });

  testWidgets('nessuna generazione: stato vuoto', (t) async {
    await pumpHub(t, serverState(), location: '/server/creativo/history');
    await settle(t);
    expect(msText('Nessuna versione'), findsOneWidget);
  });

  testWidgets('golden: Storia, admin, differenze aperte', (t) async {
    await expectHubGolden(
      t,
      'server_history_admin',
      serverState(),
      location: _loc,
      size: const Size(1280, 1500),
      prepare: (t) async {
        await settle(t);
        await t.tap(msButtonSem('Mostra le differenze di #40'));
        await settle(t);
      },
    );
  });

  testWidgets('golden: Storia, membro', (t) async {
    await expectHubGolden(
      t,
      'server_history_member',
      serverState(me: bob),
      location: _loc,
      size: const Size(1280, 1000),
      prepare: settle,
    );
  });

  testWidgets('golden: Storia, telefono', (t) async {
    await expectHubGolden(
      t,
      'server_history_phone',
      serverState(),
      location: _loc,
      size: const Size(375, 2200),
      prepare: settle,
    );
  });

  testWidgets('golden: Storia, vuota', (t) async {
    await expectHubGolden(
      t,
      'server_history_empty',
      serverState(me: bob),
      location: '/server/creativo/history',
      size: const Size(1280, 700),
      prepare: settle,
    );
  });

  testWidgets('golden: conferma di eliminazione', (t) async {
    await expectHubGolden(
      t,
      'server_history_delete_dialog',
      serverState(),
      location: _loc,
      size: const Size(1280, 900),
      prepare: (t) async {
        await settle(t);
        await t.tap(msButtonSem('Elimina la versione #39'));
        await settle(t);
      },
    );
  });
}
