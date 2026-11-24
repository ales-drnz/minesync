// Dettaglio di un server: pannello Gioca per stato del lock, sul PC (copia
// locale, Java), trasferimento ed esiti, azioni, doppia conferma per
// forzare.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/l10n/format_strings.dart';
import 'package:minesync_desktop/src/l10n/l10n.dart' show Lang;
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'home_test.dart' show homeSpaces;
import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/space_fakes.dart';

const _folder = '/tmp/mondi/creativo';

const _layout = ServerLayout(
  workDir: _folder,
  label: 'run.sh',
  launch: ScriptLaunch('/tmp/mondi/creativo/run.sh', kind: ScriptKind.posix),
  loader: 'fabric',
  loaderVersion: '0.16.9',
  mcVersion: '1.21.1',
);

List<GenerationSummary> _history() {
  GenerationSummary g(int n, String who, GenerationKind kind, int hour, {int? from}) =>
      GenerationSummary(
        n: n,
        parent: n - 1,
        digest: n.toRadixString(16).padLeft(64, '0'),
        authorId: who,
        author: who,
        message: '',
        ts: DateTime.utc(2026, 11, 22, hour).millisecondsSinceEpoch,
        kind: kind,
        stats: GenerationStats(files: 1200, size: 900 << 20, added: n % 3, changed: n % 7 + 2),
        restoredFrom: from,
      );
  return [
    g(57, 'carol', GenerationKind.push, 17),
    g(56, 'bob', GenerationKind.restore, 15, from: 54),
    g(55, 'carol', GenerationKind.autosave, 12),
    g(54, 'alice', GenerationKind.push, 9),
  ];
}

/// Server "Creativo" collegato e indietro di due versioni, Java vecchio
/// scelto per questo server.
AppState serverState({
  String route = 'creativo',
  bool admin = true,
  Transfer? transfer,
  SpaceOutcome? outcome,
}) => testState(
  setup: (s) {
    s.debugSet(
      spaces: homeSpaces(),
      hub: sampleHub(admin: admin),
      route: ServerRoute(route),
    );
    s.config.links['creativo'] = _folder;
    s.config.prefs['server.creativo.java'] = sampleJavas[1].path;
    s
        .spaceState('creativo')
        .debugSet(
          baseN: 55,
          scan: const LocalScan(
            exists: true,
            layout: _layout,
            mods: 42,
            disk: DiskSpace(212 << 30, 0),
          ),
          javas: sampleJavas,
          pending: const PendingDownload(from: 55, to: 57, files: 2, bytes: 22 << 20),
          history: _history(),
          transfer: transfer,
          outcome: outcome,
        );
  },
);

const _download = Transfer(
  op: SpaceOp.pull,
  phase: 'download',
  done: 14 << 20,
  total: 22 << 20,
  files: 41,
  totalFiles: 58,
  bytesPerSecond: 3.1 * (1 << 20),
  target: 57,
);

void main() {
  setUpAll(loadFonts);

  testWidgets('libero: Gioca apre la sessione nella pagina del server', (t) async {
    final s = serverState();
    await pumpApp(t, s);
    expect(msText('Nessuno sta giocando'), findsOneWidget);
    // sotto Gioca, solo quando c'è da aspettare
    expect(msText('2 file da scaricare'), findsWidgets);
    // niente scheda "Sessione": la sessione prende il posto della panoramica
    expect(msText('Sessione'), findsNothing);
    await t.tap(msButton('Gioca'));
    await t.pump(const Duration(seconds: 1));
    expect(s.route, const ServerRoute('creativo'));
  });

  testWidgets('sul PC: copia indietro, Java troppo vecchio con quello giusto a portata', (t) async {
    final s = serverState();
    await pumpApp(t, s);
    expect(msText('2 aggiornamenti da scaricare'), findsOneWidget);
    expect(msText('2 file da scaricare'), findsWidgets);
    expect(msText('Java 17 è troppo vecchio per questo modpack'), findsOneWidget);
    await t.ensureVisible(msButton('Usa Java 21'));
    await t.pump();
    await t.tap(msButton('Usa Java 21'));
    await t.pump();
    expect(s.config.prefs['server.creativo.java'], sampleJavas[0].path);
    expect(msText('Java 17 è troppo vecchio per questo modpack'), findsNothing);
  });

  testWidgets('sul PC: memoria e spegnimento automatico di questo server', (t) async {
    final s = serverState();
    await pumpApp(t, s);
    // la barra c'è sempre, spenta finché l'interruttore è spento: il
    // pannello non cambia altezza
    MsSlider slider() => t.widget<MsSlider>(find.byType(MsSlider));
    expect(slider().onChanged, isNull);
    Finder sw(String label) =>
        find.byWidgetPredicate((w) => w is MsSwitch && w.semanticLabel == label);
    await t.ensureVisible(sw('Imposta la memoria manualmente'));
    await t.tap(sw('Imposta la memoria manualmente'));
    await t.pump();
    expect(ServerPrefs.fromPrefs(s.config.prefs, 'creativo').xmxMiB, 6144);
    expect(slider().onChanged, isNotNull);
    await t.ensureVisible(sw('Arresto automatico senza giocatori'));
    await t.pump();
    await t.tap(sw('Arresto automatico senza giocatori'));
    await t.pump();
    expect(ServerPrefs.fromPrefs(s.config.prefs, 'creativo').autostop, isFalse);
  });

  testWidgets('«Altro»: scarica, carica, verifica e cartella in un menu', (t) async {
    final s = serverState();
    await pumpApp(t, s);
    // niente più pannelli che ripetono la Storia o i dati dell'hub
    expect(msText('Storia recente'), findsNothing);
    await t.tap(msButton('Altro'));
    await t.pump();
    for (final label in [
      'Scarica dall\'hub',
      'Carica sull\'hub',
      'Verifica integrità',
      'Apri cartella',
    ]) {
      expect(find.bySemanticsLabel(label), findsOneWidget);
    }
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    expect(find.bySemanticsLabel('Verifica integrità'), findsNothing);
  });

  testWidgets('trasferimento: fase, file, byte, velocità e tempo che manca', (t) async {
    await pumpApp(t, serverState(transfer: _download));
    expect(msText('Scaricamento degli aggiornamenti (41 di 58 file)'), findsOneWidget);
    expect(msText('63%'), findsOneWidget);
    expect(msText('14 MB di 22 MB, 3,1 MB/s'), findsOneWidget);
    expect(msText('mancano circa 2 s'), findsOneWidget);
  });

  testWidgets('modifiche locali: si propone di caricarle', (t) async {
    final s = serverState(
      outcome: const OpFailed(
        SpaceOp.pull,
        SyncException(SyncErrorKind.dirtyLocal, changed: ['world/level.dat']),
      ),
    );
    await pumpApp(t, s);
    expect(msText('Modifiche non salvate su questo PC'), findsOneWidget);
    expect(msButton('Carica le modifiche locali'), findsOneWidget);
    await t.tap(msButton('Chiudi'));
    await t.pump();
    expect(s.spaceState('creativo').outcome, isNull);
  });

  testWidgets('errore dell\'hub tradotto', (t) async {
    await pumpApp(
      t,
      serverState(outcome: const OpFailed(SpaceOp.push, SyncException(SyncErrorKind.hubDiskFull))),
    );
    expect(msText('Caricamento non riuscito'), findsOneWidget);
    expect(msText('Spazio esaurito sull\'hub: avvisa l\'amministratore'), findsOneWidget);
  });

  testWidgets('un altro gioca: indirizzo da copiare, avvisami, forza solo per admin', (t) async {
    final s = serverState(route: 'survival');
    await pumpApp(t, s);
    expect(msText('bob sta giocando'), findsWidgets);
    // indirizzo fisso dell'hub con «Copia», nel pannello in alto
    expect(msText('zerotier.survival.internal'), findsOneWidget);
    expect(msButton('Copia'), findsOneWidget);
    // forzare (admin) sta nel menu «Altro»
    await t.tap(msButton('Altro'));
    await t.pump();
    expect(find.bySemanticsLabel('Forza e gioca (admin)'), findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();
    // al posto del Gioca spento: «Avvisa quando è libero»
    await t.tap(msButton('Avvisa quando è libero'));
    await t.pump();
    expect(s.notifyWhenFree('survival'), isTrue);
    expect(msButton('Avviso attivo'), findsOneWidget);

    final m = serverState(route: 'survival', admin: false);
    await pumpApp(t, m);
    await t.tap(msButton('Altro'));
    await t.pump();
    expect(find.bySemanticsLabel('Forza e gioca (admin)'), findsNothing);
  });

  testWidgets('la propria sessione rimasta appesa: «Riprendi», senza conferme', (t) async {
    final s = serverState(route: 'avventura');
    // il lock che non risponde è di questo utente
    s.debugSet(
      spaces: [
        for (final sp in homeSpaces())
          sp.id == 'avventura'
              ? SpaceSummary(
                  id: sp.id,
                  name: sp.name,
                  profile: sp.profile,
                  createdAt: sp.createdAt,
                  head: sp.head,
                  lock: LockHolder(
                    memberId: sampleMe.id,
                    name: sampleMe.name,
                    since: 0,
                    lastBeat: 0,
                    stale: true,
                    info: const LockInfo(action: 'play'),
                  ),
                )
              : sp,
      ],
    );
    await pumpApp(t, s);
    expect(msText('La tua sessione precedente non risponde'), findsWidgets);
    expect(msButton('Riprendi'), findsOneWidget);
    expect(msButton('Forza e gioca'), findsNothing);
  });

  testWidgets('stale: ore di oggi senza giorno, di un altro giorno con il giorno', (t) async {
    final s = serverState(route: 'avventura');
    await pumpApp(t, s);
    expect(
      msText(
        'Nessun segnale dalle 17:58 (6 min fa). Possibile chiusura anomala o perdita di rete.',
      ),
      findsOneWidget,
    );
    expect(msText('tutto fino alle 17:30, salvato da bob'), findsOneWidget);
    // salvataggio e ultimo segnale di ieri: l'ora sola sarebbe ambigua
    final yesterday = DateTime.utc(2026, 11, 21, 12).millisecondsSinceEpoch;
    s.debugSet(
      spaces: [
        for (final sp in s.spaces)
          sp.id == 'avventura'
              ? SpaceSummary(
                  id: sp.id,
                  name: sp.name,
                  profile: sp.profile,
                  createdAt: sp.createdAt,
                  head: GenerationSummary.fromJson({...sp.head!.toJson(), 'ts': yesterday}),
                  lock: LockHolder.fromJson({...sp.lock!.toJson(), 'lastBeat': yesterday + 60000}),
                )
              : sp,
      ],
    );
    await t.pump();
    expect(
      msText('Nessun segnale dalle 12:01 di ieri. Possibile chiusura anomala o perdita di rete.'),
      findsOneWidget,
    );
    expect(msText('tutto fino alle 12:00 di ieri, salvato da bob'), findsOneWidget);
    expect(msText('gli ultimi minuti di gioco dopo le 12:00 di ieri'), findsOneWidget);
    // anche nelle due conferme per forzare
    await t.tap(msButton('Forza e gioca'));
    await t.pump(const Duration(seconds: 1));
    expect(msText('tutto fino all\'ultimo salvataggio, delle 12:00 di ieri'), findsOneWidget);
    await t.tap(msButton('Continua…'));
    await t.pump(const Duration(seconds: 1));
    expect(msText('12:00 di ieri'), findsOneWidget);
    await t.tap(msButton('Attendi'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  });

  test('ora con il giorno: oggi, ieri, settimana, più indietro', () {
    final it = FormatStrings.of(Lang.it);
    final en = FormatStrings.of(Lang.en);
    final now = DateTime(2026, 11, 22, 18); // domenica
    expect(it.clockOn(DateTime(2026, 11, 22, 9, 5), now), '09:05');
    expect(it.clockOn(DateTime(2026, 11, 21, 23, 10), now), '23:10 di ieri');
    expect(it.clockOn(DateTime(2026, 11, 17, 8), now), '08:00 di martedì');
    expect(it.clockOn(DateTime(2026, 11, 3, 8), now), '08:00 del 3 nov');
    expect(it.clockOn(DateTime(2026, 11, 8, 8), now), "08:00 dell'8 nov");
    expect(it.clockOn(DateTime(2026, 10, 1, 8), now), "08:00 dell'1 ott");
    expect(en.clockOn(DateTime(2026, 11, 22, 9, 5), now), '09:05');
    expect(en.clockOn(DateTime(2026, 11, 21, 23, 10), now), '23:10 yesterday');
    expect(en.clockOn(DateTime(2026, 11, 17, 8), now), '08:00 on Tuesday');
    expect(en.clockOn(DateTime(2026, 11, 3, 8), now), '08:00 on 3 Nov');
  });

  testWidgets('stale: doppia conferma prima di forzare', (t) async {
    final s = serverState(route: 'avventura');
    await pumpApp(t, s);
    expect(msText('L\'app di carol non risponde'), findsWidgets);
    await t.tap(msButton('Forza e gioca'));
    await t.pump(const Duration(seconds: 1));
    expect(msText('Liberare Avventura?'), findsOneWidget);
    await t.tap(msButton('Continua…'));
    await t.pump(const Duration(seconds: 1));
    expect(msText('Conferma finale'), findsOneWidget);
    await t.tap(msButton('Attendi'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(msText('Conferma finale'), findsNothing);
    expect(s.route, const ServerRoute('avventura'));
  });

  testWidgets('non collegato: si propone la cartella sotto ~/MineSync', (t) async {
    final s = serverState(route: 'survival');
    await pumpApp(t, s);
    // la cartella proposta, usata dal primo Gioca; si cambia da «Cambia…»
    expect(msText('~/MineSync/survival'), findsOneWidget);
    expect(msText('Il server viene scaricato qui al primo avvio.'), findsOneWidget);
  });

  testWidgets('server sparito dall\'hub', (t) async {
    await pumpApp(t, serverState(route: 'nessuno'));
    expect(msText('Questo server è stato eliminato dall\'hub'), findsOneWidget);
  });

  testWidgets('server libero con trasferimento: golden', (t) async {
    await expectAppGolden(
      t,
      'server_free',
      serverState(transfer: _download),
      size: const Size(1280, 1560),
    );
  });

  testWidgets('server in gioco: golden', (t) async {
    await expectAppGolden(
      t,
      'server_playing',
      serverState(route: 'survival'),
      size: const Size(1280, 1400),
    );
  });

  testWidgets('server stale: golden', (t) async {
    await expectAppGolden(
      t,
      'server_stale',
      serverState(route: 'avventura'),
      size: const Size(1280, 1400),
    );
  });

  testWidgets('forza e gioca, seconda conferma: golden', (t) async {
    final s = serverState(route: 'survival');
    await pumpApp(t, s);
    await t.tap(msButton('Altro'));
    await t.pump();
    // ultima voce del menu «Altro», da tastiera
    await t.sendKeyEvent(LogicalKeyboardKey.end);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump(const Duration(seconds: 1));
    await t.tap(msButton('Continua…'));
    await t.pump(const Duration(seconds: 1));
    await expectAppGolden(t, 'force_confirm', s, dprs: [1.0]);
  });
}
