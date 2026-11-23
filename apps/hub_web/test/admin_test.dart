// Area Admin: ogni sezione con le sue modifiche (corpo della PATCH), errori
// di validazione sul campo, Ripristina e predefinito, conferme (ruoli,
// pulizia, token), errori di Telegram, aggiornamento dal vivo quando un
// altro admin cambia qualcosa, golden di ogni sezione.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/pages/server/server_page.dart';
import 'package:minesync_hub_web/src/state/hub_state.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/admin_fixtures.dart';
import 'support/harness.dart';

/// Stato da admin con l'API finta dell'area Admin.
(HubState, AdminFakeApi) adminState({Me me = alice}) {
  final api = AdminFakeApi(hub: sampleHub(me: me));
  return (testState(api: api), api);
}

Future<void> openAdmin(
  WidgetTester t,
  HubState s,
  String section, {
  Size size = const Size(1280, 2400),
}) async {
  await pumpHub(t, s, location: '/admin/$section', size: size);
  await settle(t);
}

/// Attende il salvataggio automatico.
Future<void> autosave(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 1300));
  await settle(t);
}

/// Casella di testo con l'etichetta per i lettori di schermo [label].
Finder input(String label) =>
    find.byWidgetPredicate((w) => w is MsTextInput && w.semanticLabel == label);

/// Pulsante con l'etichetta per i lettori di schermo [label].
Finder semButton(String label) =>
    find.byWidgetPredicate((w) => w is MsButton && w.semanticLabel == label);

/// Una PATCH di [section] con esattamente [fields].
void expectPatch((String, Map<String, Object?>) p, String section, Map<String, Object?> fields) {
  expect(p.$1, section);
  expect(p.$2, fields);
}

Finder toastTitled(String title) => find.byWidgetPredicate((w) => w is MsToast && w.title == title);

void main() {
  setUpAll(loadFonts);

  group('Generale', () {
    testWidgets('nome: PATCH dopo la pausa, Modificato, era, Ripristina', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'general');
      expect(msText('Predefinito: MineSync, 7 di 40 caratteri'), findsOneWidget);
      await t.enterText(input('Nome dell\'hub'), 'Hub nuovo');
      await t.pump();
      // prima della pausa niente PATCH, c'è la barra delle modifiche
      expect(api.patches, isEmpty);
      expect(
        find.byWidgetPredicate((w) => w is MsPill && w.label == '1 modifica non salvata'),
        findsOneWidget,
      );
      await autosave(t);
      expectPatch(api.patches.single, 'general', {'name': 'Hub nuovo'});
      expect(toastTitled('Salvato e attivo'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is MsPill && w.label == 'Modificato'), findsOneWidget);
      expect(msText('era Homelab'), findsOneWidget);
      await t.tap(msButton('Ripristina'));
      await autosave(t);
      expectPatch(api.patches.last, 'general', {'name': 'Homelab'});
    });

    testWidgets('nome vuoto: errore sul campo, nessuna PATCH', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'general');
      await t.enterText(input('Nome dell\'hub'), '   ');
      await autosave(t);
      expect(msText('Inserisci un nome'), findsOneWidget);
      expect(api.patches, isEmpty);
    });

    testWidgets('lingua: un tocco e si salva', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'general');
      await t.tap(find.bySemanticsLabel('English').last);
      await autosave(t);
      expectPatch(api.patches.single, 'general', {'language': 'en'});
    });

    testWidgets('Salva e applica subito, Annulla toglie la bozza', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'general');
      await t.enterText(input('Nome dell\'hub'), 'Altro nome');
      await t.pump();
      await t.tap(msButton('Annulla'));
      await autosave(t);
      expect(api.patches, isEmpty);
      expect(find.text('Homelab'), findsWidgets);
      await t.enterText(input('Nome dell\'hub'), 'Altro nome');
      await t.pump();
      await t.tap(msButton('Salva e applica'));
      await settle(t);
      expectPatch(api.patches.single, 'general', {'name': 'Altro nome'});
    });

    testWidgets('un altro admin cambia il nome: la pagina si aggiorna (evento settings)', (
      t,
    ) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'general');
      api.hubSettings = HubSettings(
        sections: const SettingsSections(general: GeneralSettings(name: 'Hub di carol')),
        changed: SettingsChange(by: 'carol', byId: carol.id, at: at(17, 59), section: 'general'),
      );
      s.debugSet(events: [...s.events.reversed, settingsEvent(99, 'general')]);
      await settle(t);
      expect(find.text('Hub di carol'), findsWidgets);
      expect(msTextContaining('Ultima modifica: carol, oggi 17:59'), findsOneWidget);
      expect(api.patches, isEmpty);
    });
  });

  group('validazione', () {
    testWidgets('fuori dai limiti: errore locale con i limiti, nessuna PATCH', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'members');
      await t.enterText(input('Aggiorna l\'elenco dei membri ogni'), '5');
      await autosave(t);
      expect(msText('Scrivi un numero da 10 a 3.600'), findsOneWidget);
      expect(api.patches, isEmpty);
    });

    testWidgets('rifiutato dall\'hub (details.field): errore su quel campo', (t) async {
      final (s, api) = adminState();
      api.patchError = fieldError('sessions.autosaveMinutes');
      await openAdmin(t, s, 'sessions');
      await t.enterText(input('Salvataggio automatico ogni'), '7');
      await autosave(t);
      expectPatch(api.patches.single, 'sessions', {'autosaveMinutes': 7});
      expect(msText('Scrivi un numero da 1 a 1.440'), findsOneWidget);
      expect(toastTitled('Valore non valido: sessions.autosaveMinutes'), findsOneWidget);
    });

    testWidgets('Usa il predefinito riporta il valore di fabbrica', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'history');
      // keepDays è 14, il predefinito 7
      expect(msText('Predefinito: 7 giorni'), findsOneWidget);
      await t.tap(msButton('Usa il predefinito'));
      await autosave(t);
      expectPatch(api.patches.single, 'history', {'keepDays': 7});
    });
  });

  group('Storia e disco', () {
    testWidgets('disco, spazio per server e anteprima con le regole in bozza', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'history');
      expect(api.calls, contains('gcPreview keep=null history=30/24/14'));
      expect(msText('soglia di blocco: 1,0 GB'), findsOneWidget);
      expect(msText('Creativo: da 128 a 44 versioni'), findsOneWidget);
      expect(msText('regole proprie'), findsOneWidget);
      await t.enterText(input('Conserva sempre le ultime'), '10');
      await t.pump(const Duration(milliseconds: 500));
      await settle(t);
      expect(api.calls, contains('gcPreview keep=null history=10/24/14'));
      expect(msText('Survival: da 41 a 24 versioni'), findsOneWidget);
    });

    testWidgets('spazio minimo: vale il più alto dei due, con il valore di oggi', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'history');
      // 2 % di 2 TB = 40 GB > 1 GiB
      expect(msText('attualmente 40 GB (il 2 % di 2,0 TB)'), findsOneWidget);
      await t.enterText(input('Spazio libero minimo GiB'), '100');
      await t.pump();
      expect(msText('attualmente 100 GB (i 100 GiB)'), findsOneWidget);
      await autosave(t);
      expectPatch(api.patches.single, 'disk', {'minFreeGiB': 100});
    });

    testWidgets('pulizia manuale: anteprima, conferma, POST /gc', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'history');
      expect(api.calls, contains('gcPreview keep=20 history=null'));
      expect(msTextContaining('libererebbe circa'), findsOneWidget);
      await t.tap(msButton('Pulisci tutti i server…'));
      await settle(t);
      expect(msText('Pulire tutti i server?'), findsOneWidget);
      await t.tap(msButton('Annulla'));
      await settle(t);
      expect(api.calls.where((c) => c.startsWith('gc ')), isEmpty);
      await t.tap(msButton('Pulisci tutti i server…'));
      await settle(t);
      await t.tap(msButton('Pulisci ora'));
      await settle(t);
      expect(api.calls, contains('gc null 20'));
      expect(
        toastTitled('Pulizia completata: 118 versioni eliminate, 5,0 GB liberati'),
        findsOneWidget,
      );
    });
  });

  group('Accesso e membri', () {
    testWidgets('ZTNET, valori mascherati con la variabile, membri', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'members');
      expect(msText('Connesso a ZTNET'), findsOneWidget);
      expect(msTextContaining(', 3 membri autorizzati sulla rete.'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is MsCode && w.text == '•••••••••••• 7f2a'),
        findsOneWidget,
      );
      expect(msText('ZTNET_API_TOKEN'), findsOneWidget);
      expect(msText('impostato all\'avvio'), findsNWidgets(3));
      expect(msText('tu'), findsOneWidget);
      expect(msText('Non rimovibile'), findsOneWidget);
      expect(msText('Non autorizzato'), findsOneWidget);
      expect(msText('senza nome'), findsOneWidget);
      expect(semButton('Rendi membro alice'), findsNothing);
    });

    testWidgets('Verifica ora rilegge ZTNET', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'members');
      await t.tap(msButton('Verifica ora'));
      await settle(t);
      expect(api.calls, contains('refreshMembers'));
      expect(toastTitled('ZTNET verificato'), findsOneWidget);
    });

    testWidgets('Rendi admin: conferma, PUT del ruolo; Annulla non cambia nulla', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'members');
      await t.tap(semButton('Rendi admin bob'));
      await settle(t);
      expect(msText('Rendere admin bob?'), findsOneWidget);
      await t.tap(msButton('Annulla'));
      await settle(t);
      expect(api.calls.where((c) => c.startsWith('setRole')), isEmpty);
      await t.tap(semButton('Rendi admin bob'));
      await settle(t);
      await t.tap(msButton('Rendi admin').last);
      await settle(t);
      expect(api.calls, contains('setRole ${bob.id} admin'));
      expect(toastTitled('bob ora è admin'), findsOneWidget);
      expect(semButton('Rendi membro bob'), findsOneWidget);
    });

    testWidgets('409 last_admin e from_config: il motivo in una notifica', (t) async {
      final (s, api) = adminState();
      api.roleError = const ApiError(ErrorCode.lastAdmin, 'last admin');
      await openAdmin(t, s, 'members');
      await t.tap(semButton('Rendi membro carol'));
      await settle(t);
      await t.tap(msButton('Rendi membro').last);
      await settle(t);
      expect(toastTitled('Serve almeno un admin'), findsOneWidget);
      api.roleError = const ApiError(ErrorCode.fromConfig, 'from config');
      await t.tap(semButton('Rendi membro carol'));
      await settle(t);
      await t.tap(msButton('Rendi membro').last);
      await settle(t);
      expect(toastTitled('Questo admin è fissato nella configurazione dell\'hub'), findsOneWidget);
    });

    testWidgets('ricerca per nome, node id o IP', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'members');
      await t.enterText(input('Cerca membro'), '192.0.2.12');
      await t.pump();
      expect(msText('carol'), findsOneWidget);
      expect(msText('bob'), findsNothing);
      await t.enterText(input('Cerca membro'), 'zzz');
      await t.pump();
      expect(msText('Nessun membro corrisponde alla ricerca'), findsOneWidget);
    });
  });

  group('Sessioni e protezioni', () {
    testWidgets('server con valori propri e link alla sua Amministrazione', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'sessions');
      expect(msText('1 server ha valori propri'), findsOneWidget);
      expect(
        msText('Avventura: salvataggio ogni 10 min, 3 riavvii. Gli altri ereditano questi.'),
        findsOneWidget,
      );
      await t.tap(msButton('Apri Avventura'));
      await settle(t);
      expect(find.byWidgetPredicate((w) => w is ServerPage && w.id == 'avventura'), findsOneWidget);
    });

    testWidgets('spegnimento automatico: interruttore e minuti', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'sessions');
      await t.tap(find.bySemanticsLabel('Arresta il server se resta vuoto').last);
      await autosave(t);
      expectPatch(api.patches.single, 'sessions', {'autostop': false});
    });

    testWidgets('soglia: esempio su un server vero, PATCH con il rapporto', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'protection');
      expect(
        msText('Su Survival (1.200 file) un salvataggio che ne toglie più di 480 viene rifiutato.'),
        findsOneWidget,
      );
      await t.enterText(input('Rifiuta i salvataggi che tolgono più del'), '25');
      await t.pump();
      expect(msTextContaining('più di 300 viene rifiutato'), findsOneWidget);
      await autosave(t);
      expectPatch(api.patches.single, 'protection', {'massDeleteRatio': 0.25});
      await t.enterText(input('Solo se il server ha almeno'), '5000');
      await t.pump();
      expect(
        msText('Su Survival (1.200 file) la regola non si applica: servono almeno 5.000 file.'),
        findsOneWidget,
      );
    });

    testWidgets('statistiche: sessioni conservate', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'stats');
      await t.enterText(input('Sessioni conservate per server'), '80');
      await autosave(t);
      expectPatch(api.patches.single, 'stats', {'sessionsKept': 80});
    });
  });

  group('Esclusioni', () {
    testWidgets('aggiungi e togli pattern; quelli di sistema sono bloccati', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'exclusions');
      expect(
        find.byWidgetPredicate(
          (w) => w is MsSegmented<Profile> && w.segments.first.label == 'Minecraft (3 server)',
        ),
        findsOneWidget,
      );
      expect(semButton('Rimuovi .minesync*'), findsNothing);
      await t.enterText(input('Nuovo pattern'), 'bluemap/**');
      await t.tap(msButton('Aggiungi'));
      await t.pump();
      await t.tap(semButton('Rimuovi logs/**'));
      await autosave(t);
      final (sec, f) = api.patches.single;
      expect(sec, 'exclusions');
      final list = f['minecraft']! as List;
      expect(list, contains('bluemap/**'));
      expect(list, isNot(contains('logs/**')));
      await t.enterText(input('Nuovo pattern'), '*.lock');
      await t.tap(msButton('Aggiungi'));
      await t.pump();
      expect(msText('Pattern già presente'), findsOneWidget);
    });

    testWidgets('prova un percorso: escluso da quale regola, oppure va sull\'hub', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'exclusions');
      await t.enterText(input('Verifica un percorso'), 'logs/latest.log');
      await t.tap(msButton('Verifica'));
      await settle(t);
      expect(api.calls, contains('testExclusion logs/latest.log ${minecraftExclusions.length}'));
      expect(find.byWidgetPredicate((w) => w is MsPill && w.label == 'Escluso'), findsOneWidget);
      expect(find.byWidgetPredicate((w) => w is MsCode && w.text == 'logs/**'), findsWidgets);
      await t.enterText(input('Verifica un percorso'), 'world/region/r.0.0.mca');
      await t.tap(msButton('Verifica'));
      await settle(t);
      expect(
        find.byWidgetPredicate((w) => w is MsPill && w.label == 'Inviato all\'hub'),
        findsOneWidget,
      );
    });
  });

  group('Telegram', () {
    testWidgets('stato e token mai mostrato per intero', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'telegram');
      expect(msText('Attivo nella chat «Amici del server»'), findsOneWidget);
      expect(
        msText('Ultimo messaggio oggi 17:52: «Survival salvato sull\'hub». Nessun errore.'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate((w) => w is MsCode && w.text == '•••••••••••• 0000'),
        findsOneWidget,
      );
    });

    testWidgets('messaggio di prova: arrivato, oppure 502, 429, 400 sotto il pulsante', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'telegram');
      await t.tap(msButton('Invia un messaggio di prova'));
      await settle(t);
      expect(toastTitled('Messaggio di prova ricevuto alle 17:58'), findsOneWidget);
      api.telegramTestError = upstreamError('Bad Request: chat not found');
      await t.tap(msButton('Invia un messaggio di prova'));
      await settle(t);
      expect(
        msText(
          'Invio di prova non riuscito: Errore del servizio esterno: Bad Request: chat not found',
        ),
        findsOneWidget,
      );
      api.telegramTestError = const ApiError(ErrorCode.rateLimited, 'slow down');
      await t.tap(msButton('Invia un messaggio di prova'));
      await settle(t);
      expect(
        msText('Invio di prova non riuscito: Troppe richieste: riprova tra qualche secondo'),
        findsOneWidget,
      );
      api.telegramTestError = const ApiError(ErrorCode.badRequest, 'nothing configured');
      await t.tap(msButton('Invia un messaggio di prova'));
      await settle(t);
      expect(msText('Invio di prova non riuscito: Richiesta non valida'), findsOneWidget);
    });

    testWidgets('prova del topic di una riga', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'telegram');
      expect(msText('chat principale'), findsNWidgets(2));
      await t.tap(semButton('Verifica il topic di Creativo'));
      await settle(t);
      expect(api.calls, contains('testTelegram space=creativo topic=null chat=null'));
      expect(msText('Ricevuto alle 17:58'), findsOneWidget);
    });

    testWidgets('Trova chat e Usa questa: la chat si salva', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'telegram');
      await t.tap(msButton('Come trovare l\'ID della chat'));
      await t.pump();
      await t.tap(msButton('Trova chat'));
      await settle(t);
      expect(msText('Gruppo di prova'), findsOneWidget);
      await t.tap(msButton('Usa questa'));
      await autosave(t);
      expect(api.telegramPatches.single, {'chat': '-1000000000002'});
    });

    testWidgets('cosa annunciare e minuti: PATCH /telegram', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'telegram');
      await t.tap(find.bySemanticsLabel(RegExp('^Avvisi')).first);
      await t.enterText(input('Unisci chiusura e riapertura entro'), '5');
      await autosave(t);
      expect(api.telegramPatches.single, {
        'notify': {'open': true, 'close': true, 'alerts': false, 'status': true},
        'coalesceMinutes': 5,
      });
    });

    testWidgets('Sostituisci e Rimuovi il token', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'telegram');
      await t.tap(msButton('Sostituisci'));
      await settle(t);
      await t.enterText(
        find.descendant(of: find.byType(MsDialog), matching: find.byType(MsTextInput)),
        '123:${'a' * 35}',
      );
      await t.tap(msButton('Salva'));
      await settle(t);
      expect(api.telegramPatches.single, {'token': '123:${'a' * 35}'});
      expect(
        find.byWidgetPredicate((w) => w is MsCode && w.text == '•••••••••••• aaaa'),
        findsOneWidget,
      );
      await t.tap(msButton('Rimuovi'));
      await settle(t);
      await t.tap(msButton('Rimuovi il token'));
      await settle(t);
      expect(api.telegramPatches.last, {'enabled': false, 'removeToken': true});
      expect(msText('Nessun token'), findsOneWidget);
    });
  });

  group('Sistema e cornice', () {
    testWidgets('valori di sola lettura con la variabile d\'ambiente', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'system');
      expect(msText('0.1.0 (build 2026-11-14)'), findsOneWidget);
      expect(msText('12 giorni 4 ore'), findsOneWidget);
      expect(msText('MINESYNC_ADDR'), findsOneWidget);
      expect(msText('zona minesync.internal su :53'), findsOneWidget);
      expect(msText('Chiave presente'), findsOneWidget);
      expect(msText('build 3f9a1c2b7d4e'), findsOneWidget);
      await t.tap(msButton('Copia diagnostica'));
      await settle(t);
      expect(fakePlatform(s).copied.single, startsWith('MineSync hub 0.1.0 (2026-11-14)'));
    });

    testWidgets('strip di stato e segnali nel menu', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'general');
      expect(msText('3 membri, 2 admin'), findsOneWidget);
      expect(msText('liberi 1,2 TB'), findsOneWidget);
      expect(msText('ultimo 17:52'), findsOneWidget);
      expect(msText('firmati (3 app)'), findsOneWidget);
    });

    testWidgets('cerca un\'impostazione e vai alla sezione', (t) async {
      final (s, _) = adminState();
      await openAdmin(t, s, 'general');
      await t.enterText(input('Cerca un\'impostazione'), 'autosave');
      await t.pump();
      await t.tap(
        find.byWidgetPredicate((w) => w is MsListRow && w.title == 'Salvataggio automatico ogni'),
      );
      await settle(t);
      expect(documentTitle(t), 'Sessioni di gioco (Homelab)');
      expect(msText('1 server ha valori propri'), findsOneWidget);
    });

    testWidgets('uscendo dalla sezione la bozza si salva', (t) async {
      final (s, api) = adminState();
      await openAdmin(t, s, 'stats');
      await t.enterText(input('Sessioni conservate per server'), '60');
      await t.pump();
      await t.tap(find.bySemanticsLabel('Generale').first);
      await settle(t);
      expectPatch(api.patches.single, 'stats', {'sessionsKept': 60});
    });

    testWidgets('impostazioni non leggibili: errore con Riprova', (t) async {
      final (s, api) = adminState();
      api.hubSettings = null;
      await openAdmin(t, s, 'general');
      expect(msText('Impossibile leggere le impostazioni'), findsOneWidget);
      api.hubSettings = sampleSettings();
      await t.tap(msButton('Riprova'));
      await settle(t);
      expect(msText('Nome dell\'hub'), findsOneWidget);
    });
  });

  group('golden', () {
    for (final sec in [
      'general',
      'members',
      'history',
      'sessions',
      'protection',
      'exclusions',
      'telegram',
      'stats',
      'system',
    ]) {
      testWidgets('golden: $sec', (t) async {
        final (s, _) = adminState();
        await expectHubGolden(
          t,
          'admin_$sec',
          s,
          location: '/admin/$sec',
          size: const Size(1280, 1500),
          prepare: settle,
        );
      });
    }

    testWidgets('golden: modifica in attesa con Modificato e barra in basso', (t) async {
      final (s, _) = adminState();
      await expectHubGolden(
        t,
        'admin_pending',
        s,
        location: '/admin/sessions',
        size: const Size(1280, 1100),
        prepare: (t) async {
          await settle(t);
          await t.enterText(input('Salvataggio automatico ogni'), '10');
          await t.pump();
        },
      );
    });

    testWidgets('golden: telefono, menu e Generale', (t) async {
      final (s, _) = adminState();
      await expectHubGolden(
        t,
        'admin_phone_menu',
        s,
        location: '/admin/general',
        size: const Size(375, 2000),
        prepare: settle,
      );
    });

    testWidgets('golden: telefono, Telegram (sezione lunga)', (t) async {
      final (s, _) = adminState();
      await expectHubGolden(
        t,
        'admin_phone_telegram',
        s,
        location: '/admin/telegram',
        size: const Size(375, 4200),
        prepare: settle,
      );
    });
  });
}
