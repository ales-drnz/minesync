// Pagina Server, intestazione e Panoramica: chip e conteggi, lock in gioco
// (indirizzi da copiare, prova della porta), rilascio forzato con doppia
// conferma (admin) o una conferma (stale), mondo, server, statistiche,
// aggiornamenti dal vivo, golden.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_hub_web/src/l10n/l10n.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import '../support/harness.dart';
import '../support/server_fixtures.dart';
import '../support/server_helpers.dart';

const _tall = Size(1280, 2200);

void main() {
  setUpAll(loadFonts);

  testWidgets('intestazione: chip, #HEAD, lock, schede con conteggi, zip della HEAD', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    expect(msText('Survival'), findsWidgets);
    expect(msText('#41'), findsWidgets);
    for (final c in ['Minecraft 1.21.1', 'Fabric 0.16.5', '42 mod', '18 GB sull\'hub']) {
      expect(find.byWidgetPredicate((w) => w is MsChip && w.label == c), findsOneWidget, reason: c);
    }
    expect(find.bySemanticsLabel(RegExp(r'^Giocatori.*4')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp(r'^Storia.*41')), findsOneWidget);
    await tapOn(t, msButton('Scarica zip'));
    expect(
      fakePlatform(s).downloads.single.toString(),
      'http://192.0.2.1/api/v1/spaces/survival/generations/41/zip',
    );
  });

  testWidgets('in gioco: giocatori, indirizzo fisso e IP diretto da copiare, porta', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    expect(msText('3 online: bob (host), carol, alice'), findsOneWidget);
    expect(msTextContaining('in sessione da 1 h 14 min'), findsOneWidget);
    await tapOn(t, msButtonSem('Copia indirizzo fisso'));
    await tapOn(t, msButtonSem('Copia IP diretto'));
    expect(fakePlatform(s).copied, ['zerotier.survival.minesync.internal', '192.0.2.10:25565']);
    expect(
      find.byWidgetPredicate((w) => w is MsPill && w.label == 'Raggiungibile'),
      findsOneWidget,
    );
    expect(msText('porta 25565 verificata dall\'hub alle 17:52'), findsOneWidget);
  });

  testWidgets('"Ripeti il test" rilancia la prova della porta; un rifiuto diventa un avviso', (
    t,
  ) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    await tapOn(t, msButton('Ripeti la verifica'));
    expect(fakeApi(s).calls, contains('portCheck survival'));
    expect(
      find.byWidgetPredicate((w) => w is MsPill && w.label == 'Verifica in corso'),
      findsOneWidget,
    );
    fakeApi(s).failOn['portCheck'] = const ApiError(ErrorCode.rateLimited, 'x');
    await tapOn(t, msButton('Ripeti la verifica'));
    expect(toasts(t), contains('Troppe richieste: riprova tra qualche secondo'));
  });

  testWidgets('admin: "Forza rilascio" chiede due conferme', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    await tapOn(t, msButton('Forza rilascio'));
    expect(msText('Forzare il rilascio di Survival?'), findsOneWidget);
    // annullare al primo passo non fa niente
    await tapOn(t, msButton('Annulla'));
    expect(fakeApi(s).calls, isNot(contains('forceReleaseLock survival')));
    await tapOn(t, msButton('Forza rilascio'));
    await tapOn(t, msButton('Continua'));
    expect(msText('Confermare il rilascio forzato?'), findsOneWidget);
    expect(fakeApi(s).calls, isNot(contains('forceReleaseLock survival')));
    await tapOn(
      t,
      find.descendant(of: find.byType(MsDialog), matching: msButton('Forza rilascio')),
    );
    expect(fakeApi(s).calls, contains('forceReleaseLock survival'));
    expect(toasts(t), contains('Lock di Survival liberato'));
  });

  testWidgets('membro: il lock attivo non si forza', (t) async {
    final s = serverState(me: bob);
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    expect(disabled(t, msButton('Forza rilascio')), isTrue);
    expect(msTextContaining('Solo un admin può forzare un lock attivo'), findsOneWidget);
  });

  testWidgets('stale: chiunque lo libera con una conferma', (t) async {
    final s = serverState(me: bob);
    await pumpHub(t, s, location: '/server/avventura', size: _tall);
    await settle(t);
    expect(msText('L\'app di carol potrebbe essersi chiusa in modo anomalo'), findsOneWidget);
    await tapOn(t, msButton('Libera il lock'));
    expect(msText('Liberare il lock di carol?'), findsOneWidget);
    await tapOn(
      t,
      find.descendant(of: find.byType(MsDialog), matching: msButton('Libera il lock')),
    );
    expect(fakeApi(s).calls, contains('forceReleaseLock avventura'));
  });

  testWidgets('rilascio rifiutato dall\'hub: avviso con il motivo', (t) async {
    final s = serverState(
      me: bob,
      setup: (a) => a.failOn['forceReleaseLock'] = const ApiError(ErrorCode.forbidden, 'x'),
    );
    await pumpHub(t, s, location: '/server/avventura', size: _tall);
    await settle(t);
    await tapOn(t, msButton('Libera il lock'));
    await tapOn(
      t,
      find.descendant(of: find.byType(MsDialog), matching: msButton('Libera il lock')),
    );
    expect(toasts(t), contains('Solo un admin può farlo'));
  });

  testWidgets('libero: ultima sessione e come entrare', (t) async {
    await pumpHub(t, serverState(), location: '/server/creativo', size: _tall);
    await settle(t);
    expect(msText('Nessuno ospita. Ultima sessione: carol, ieri 20:42–22:47.'), findsOneWidget);
    expect(
      msTextContaining('Gli altri giocatori entrano su zerotier.creativo.minesync.internal.'),
      findsOneWidget,
    );
    expect(msButton('Forza rilascio'), findsNothing);
  });

  testWidgets('mondo e server: level.dat, server.properties, seed da copiare', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    expect(msText('Survival dei Pini'), findsOneWidget);
    expect(msText('Normale (hardcore no)'), findsOneWidget);
    expect(msText('Sopravvivenza'), findsOneWidget);
    expect(msText('giorno 412, 137 h di mondo'), findsOneWidget);
    expect(msText('X 128, Y 72, Z −340'), findsOneWidget);
    await tapOn(t, msButtonSem('Copia seed'));
    expect(fakePlatform(s).copied, ['-4172144997902289642']);
    expect(msText('Benvenuti su Survival'), findsOneWidget);
    expect(msText('3 nomi'), findsOneWidget);
    expect(msText('12 chunk'), findsOneWidget);
  });

  testWidgets('statistiche: classifiche, sessioni, quella in corso', (t) async {
    await pumpHub(t, serverState(), location: '/server/survival', size: _tall);
    await settle(t);
    expect(msText('Ore in gioco'), findsOneWidget);
    expect(msText('61 h'), findsOneWidget);
    expect(msText('5 h 42 min (bob)'), findsOneWidget);
    expect(msText('in corso'), findsOneWidget);
    expect(msText('Conservate le ultime 40 per server.'), findsOneWidget);
  });

  testWidgets('dal vivo: una HEAD nuova rilegge mondo e storia', (t) async {
    final s = serverState();
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    final api = fakeApi(s);
    int worldCalls() => api.calls.where((c) => c == 'world survival').length;
    expect(worldCalls(), 1);
    final sp = s.space('survival')!;
    s.debugSet(
      spaces: [
        for (final x in s.spaces)
          x.id != 'survival'
              ? x
              : SpaceSummary(
                  id: sp.id,
                  name: sp.name,
                  profile: sp.profile,
                  createdAt: sp.createdAt,
                  head: sampleGen(42, author: 'bob'),
                  lock: sp.lock,
                  dnsName: sp.dnsName,
                  world: sp.world,
                ),
      ],
    );
    await settle(t);
    expect(worldCalls(), 2);
    expect(api.calls.where((c) => c.startsWith('generations survival')).length, 2);
  });

  testWidgets('in inglese', (t) async {
    final s = serverState(setup: (_) {});
    s.setLang(Lang.en);
    await pumpHub(t, s, location: '/server/survival', size: _tall);
    await settle(t);
    expect(msText('Session and address'), findsOneWidget);
    expect(msText('3 online: bob (host), carol, alice'), findsOneWidget);
    expect(msText('Normal (hardcore no)'), findsOneWidget);
  });

  testWidgets('golden: Panoramica, admin', (t) async {
    await expectHubGolden(
      t,
      'server_overview_admin',
      serverState(),
      location: '/server/survival',
      size: const Size(1280, 2100),
      prepare: settle,
    );
  });

  testWidgets('golden: Panoramica, membro, server libero', (t) async {
    await expectHubGolden(
      t,
      'server_overview_member_free',
      serverState(me: bob),
      location: '/server/creativo',
      size: const Size(1280, 1500),
      prepare: settle,
    );
  });

  testWidgets('golden: Panoramica, stale', (t) async {
    await expectHubGolden(
      t,
      'server_overview_stale',
      serverState(me: bob),
      location: '/server/avventura',
      size: const Size(1280, 1500),
      prepare: settle,
    );
  });

  testWidgets('golden: Panoramica, telefono', (t) async {
    await expectHubGolden(
      t,
      'server_overview_phone',
      serverState(),
      location: '/server/survival',
      size: const Size(375, 4300),
      prepare: settle,
    );
  });
}
