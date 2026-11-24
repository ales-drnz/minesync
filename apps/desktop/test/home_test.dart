// Home: card dei server per stato del lock, avvisi, attività, stato vuoto,
// dialogo "Nuovo server".
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/l10n/l10n.dart';
import 'package:minesync_desktop/src/screens/screens.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_ui/ms_ui.dart';

import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/space_fakes.dart';

/// Attività di esempio (la più vecchia per prima).
List<HubEvent> sampleEvents() {
  int at(int h, int m) => DateTime.utc(2026, 11, 22, h, m).millisecondsSinceEpoch;
  return [
    HubEvent(
      seq: 1,
      ts: DateTime.utc(2026, 11, 21, 21).millisecondsSinceEpoch,
      type: 'gc',
      data: const {'generations': 12, 'blobs': 40, 'bytes': 3 << 30},
    ),
    HubEvent(
      seq: 2,
      ts: at(15, 20),
      type: 'restore',
      space: 'creativo',
      actor: 'bob',
      data: const {'n': 56, 'restoredFrom': 54},
    ),
    HubEvent(seq: 3, ts: at(16, 55), type: 'unlock', space: 'creativo', actor: 'alice'),
    HubEvent(seq: 4, ts: at(17, 30), type: 'lock', space: 'survival', actor: 'bob'),
    HubEvent(
      seq: 5,
      ts: at(18, 2),
      type: 'force',
      space: 'avventura',
      actor: 'alice',
      data: const {'from': 'carol'},
    ),
    HubEvent(
      seq: 6,
      ts: at(18, 3),
      type: 'push',
      space: 'survival',
      actor: 'bob',
      data: const {
        'n': 128,
        'kind': 'autosave',
        'stats': {'files': 1200, 'size': 38 << 20, 'added': 0, 'changed': 4, 'removed': 0},
      },
    ),
  ];
}

/// Stato della Home come nel canvas: un server collegato con il
/// pre-scarico in corso e il layout Minecraft riconosciuto.
/// Server di esempio con l'indirizzo di chi ospita e un lock stale recente.
List<SpaceSummary> homeSpaces() {
  final base = sampleSpaces();
  final ms = DateTime.utc(2026, 11, 22, 17, 58).millisecondsSinceEpoch;
  SpaceSummary withLock(
    SpaceSummary sp,
    LockHolder? l, {
    String? dnsName,
    WorldChip? world,
    SessionRecord? lastSession,
  }) => SpaceSummary(
    id: sp.id,
    name: sp.name,
    profile: sp.profile,
    createdAt: sp.createdAt,
    head: sp.head,
    lock: l,
    dnsName: dnsName,
    world: world,
    lastSession: lastSession,
  );
  final play = base[0].lock!;
  return [
    withLock(
      base[0],
      LockHolder(
        memberId: play.memberId,
        name: play.name,
        since: play.since,
        lastBeat: play.lastBeat,
        stale: false,
        ip: '192.0.2.31',
        info: const LockInfo(action: 'play', players: ['bob', 'carol'], port: 25565),
      ),
      dnsName: 'zerotier.survival.internal',
      world: const WorldChip(
        mcVersion: '1.21.1',
        loader: Loader.fabric,
        loaderVersion: '0.16.9',
        mods: 42,
      ),
    ),
    withLock(
      base[1],
      null,
      world: const WorldChip(mcVersion: '1.21.4', loader: Loader.vanilla),
      lastSession: SessionRecord(
        memberId: 'c3',
        name: 'carol',
        start: DateTime.utc(2026, 11, 21, 20).millisecondsSinceEpoch,
        end: DateTime.utc(2026, 11, 21, 22, 10).millisecondsSinceEpoch,
        ended: SessionEnd.released,
      ),
    ),
    withLock(
      base[2],
      LockHolder(
        memberId: 'c3',
        name: 'carol',
        since: ms - 3600000,
        lastBeat: ms,
        stale: true,
        info: const LockInfo(action: 'play'),
      ),
      world: const WorldChip(mcVersion: '1.21.1', loader: Loader.neoforge, mods: 212),
    ),
  ];
}

AppState homeState({bool admin = true, bool fullDisk = true}) => testState(
  setup: (s) {
    s.debugSet(
      spaces: homeSpaces(),
      events: sampleEvents(),
      hub: fullDisk ? sampleHub(admin: admin) : roomyHub(admin: admin),
    );
    s.config.links['creativo'] = '/tmp/mondi/creativo';
    s
        .spaceState('creativo')
        .debugSet(
          baseN: 55,
          scan: const LocalScan(
            exists: true,
            layout: ServerLayout(
              workDir: '/tmp/mondi/creativo',
              label: 'run.sh',
              loader: 'vanilla',
              mcVersion: '1.21.4',
            ),
          ),
          transfer: const Transfer(
            op: SpaceOp.pull,
            phase: 'download',
            done: 63,
            total: 100,
            background: true,
            target: 57,
          ),
        );
  },
);

HubInfo roomyHub({bool admin = true}) {
  final h = sampleHub(admin: admin);
  return HubInfo(
    name: h.name,
    version: h.version,
    api: h.api,
    time: h.time,
    disk: const DiskInfo(free: 900 << 30, total: 2000 << 30, minFree: 1 << 30),
    me: h.me,
  );
}

void main() {
  setUpAll(loadFonts);

  testWidgets('card per stato del lock e azioni', (t) async {
    final s = homeState();
    await pumpApp(t, s);
    await t.pump();
    // libero: Gioca porta alla sessione
    expect(msText('Gioca'), findsOneWidget);
    // in gioco: chi gioca e quanti sono online
    expect(msMeta(['2 online', 'da 34 min']), findsOneWidget);
    // stale: lo stato basta, la card offre «Cosa fare» (niente frase ripetuta)
    expect(msTextContaining('L\'app di carol non risponde'), findsNothing);
    expect(msButton('Cosa fare'), findsOneWidget);
    // pre-scarico in corso sul server collegato
    expect(msText('Download degli aggiornamenti'), findsOneWidget);
    expect(msMeta(['Vanilla', 'Minecraft 1.21.4']), findsOneWidget);
    await t.tap(msText('Gioca'));
    await t.pump();
    expect(s.route, const ServerRoute('creativo'));
  });

  testWidgets('la propria sessione rimasta appesa: «Riprendi» anche nella card', (t) async {
    final s = homeState();
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
                  lock: LockHolder.fromJson({
                    ...sp.lock!.toJson(),
                    'memberId': sampleMe.id,
                    'name': sampleMe.name,
                  }),
                )
              : sp,
      ],
    );
    await pumpApp(t, s);
    await t.pump();
    expect(msButton('Riprendi'), findsOneWidget);
    expect(msButton('Cosa fare'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is MsLock && w.meta == 'tu'), findsOneWidget);
  });

  testWidgets('avvisi: disco dell\'hub quasi pieno, offline con riprova', (t) async {
    final s = homeState();
    await pumpApp(t, s);
    expect(msTextContaining('Disco dell\'hub quasi pieno'), findsOneWidget);
    s.debugSet(
      connection: Connection.offline,
      offlineSince: sampleNow.subtract(const Duration(seconds: 40)),
    );
    await t.pump();
    expect(msText('Offline: hub non raggiungibile'), findsOneWidget);
  });

  testWidgets('attività dal vivo con i nomi dei server', (t) async {
    await pumpApp(t, homeState());
    expect(msTextContaining('ha salvato'), findsOneWidget);
    expect(msText('salvato'), findsWidgets);
    expect(msText('ieri'), findsOneWidget);
  });

  testWidgets('chi non è admin non vede "Nuovo server"', (t) async {
    await pumpApp(t, homeState(admin: false));
    expect(msText('Nuovo server'), findsNothing);
  });

  testWidgets('nuovo server: prima l\'origine, poi il nome obbligatorio', (t) async {
    final s = homeState();
    await pumpApp(t, s);
    s.go(const NewServerRoute());
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(NewServerScreen), findsOneWidget);
    await t.tap(msButton('Avanti'));
    await t.pump();
    // senza nome non si va avanti
    expect(t.widget<MsButton>(msButton('Avanti')).onPressed, isNull);
    expect(msText('Scrivi un nome'), findsOneWidget);
    await t.enterText(find.byType(EditableText).first, 'Avventura');
    await t.pump();
    expect(s.newServer.name, 'Avventura');
    expect(msText('Scrivi un nome'), findsNothing);
  });

  testWidgets('stato vuoto per admin e membro', (t) async {
    final s = testState(setup: (s) => s.debugSet(spaces: const []));
    await pumpApp(t, s);
    expect(msText('Ancora nessun server'), findsOneWidget);
    expect(msText('Crea il primo server'), findsOneWidget);
    s.debugSet(hub: sampleHub(admin: false));
    await t.pump();
    expect(msText('Crea il primo server'), findsNothing);
  });

  testWidgets('barra laterale: pre-scarico in background e Ctrl+N per un nuovo server', (t) async {
    await pumpApp(t, homeState());
    expect(msText('In background'), findsOneWidget);
    expect(msText('Il server parte subito quando premi Gioca.'), findsOneWidget);
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.keyN);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(NewServerScreen), findsOneWidget);
  });

  testWidgets('card: mondo dall\'hub, indirizzo fisso, ultima sessione', (t) async {
    await pumpApp(t, homeState());
    // server non collegati: versione e loader dalla HEAD dell'hub
    expect(msMeta(['Fabric', 'Minecraft 1.21.1']), findsOneWidget);
    expect(msMeta(['NeoForge', 'Minecraft 1.21.1']), findsOneWidget);
    // B-DNS-01: si entra dal nome fisso, non dall'IP di chi ospita
    expect(msText('zerotier.survival.internal'), findsWidgets);
    expect(msTextContaining('192.0.2.31'), findsNothing);
    // libero: chi ha giocato per ultimo, dalla sessione registrata dall'hub
    expect(msText('carol ha giocato ieri 22:10'), findsOneWidget);
  });

  testWidgets('senza DNS sull\'hub: si entra con l\'IP diretto e la porta', (t) async {
    final spaces = homeSpaces();
    final sp = spaces.first;
    spaces[0] = SpaceSummary(
      id: sp.id,
      name: sp.name,
      profile: sp.profile,
      createdAt: sp.createdAt,
      head: sp.head,
      lock: sp.lock,
    );
    final s = homeState()..debugSet(spaces: spaces);
    await pumpApp(t, s);
    expect(msText('192.0.2.31:25565'), findsWidgets);
  });

  testWidgets('disco quasi pieno: "Fai pulizia…" solo per gli admin', (t) async {
    await pumpApp(t, homeState(admin: false));
    expect(msTextContaining('Disco dell\'hub quasi pieno'), findsOneWidget);
    expect(msButton('Pulizia…'), findsNothing);

    await pumpApp(t, homeState());
    await t.tap(msButton('Pulizia…'));
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(GcDialog), findsOneWidget);
    expect(msText('Pulizia delle versioni vecchie'), findsOneWidget);
  });

  testWidgets('tutta l\'attività: anche le più vecchie, dall\'hub', (t) async {
    final s = homeState()..debugSet(olderEnd: false);
    await pumpApp(t, s, size: const Size(1280, 1400));
    // solo 6 righe in memoria, ma l'hub ne ha altre: il pulsante c'è
    await t.tap(msButton('Tutta l\'attività'));
    await t.pump();
    expect(msButton('Più vecchie'), findsOneWidget);
    expect(msButton('Meno attività'), findsOneWidget);
    s.debugSet(olderEnd: true);
    await t.pump();
    expect(msButton('Più vecchie'), findsNothing);
  });

  testWidgets('nuovi tipi di evento con testo e badge', (t) async {
    int at(int m) => DateTime.utc(2026, 11, 22, 17, m).millisecondsSinceEpoch;
    final s = homeState()
      ..debugSet(
        events: [
          HubEvent(
            seq: 10,
            ts: at(1),
            type: EventType.stale,
            space: 'avventura',
            data: const {'holder': 'carol', 'lastBeat': 0},
          ),
          HubEvent(
            seq: 11,
            ts: at(2),
            type: EventType.port,
            space: 'survival',
            data: const {'state': 'blocked', 'port': 25565},
          ),
          HubEvent(
            seq: 12,
            ts: at(3),
            type: EventType.restoreFile,
            space: 'survival',
            actor: 'alice',
            data: const {'n': 130, 'restoredFrom': 127, 'path': 'world/region/r.0.0.mca'},
          ),
          HubEvent(
            seq: 13,
            ts: at(4),
            type: EventType.generationDelete,
            space: 'survival',
            actor: 'alice',
            data: const {'n': 90, 'bytes': 3 << 20},
          ),
          HubEvent(
            seq: 14,
            ts: at(5),
            type: EventType.memberRole,
            actor: 'alice',
            data: const {'memberId': 'b2', 'member': 'bob', 'role': 'admin'},
          ),
          HubEvent(seq: 15, ts: at(6), type: EventType.ztnet, data: const {'state': 'error'}),
          HubEvent(seq: 16, ts: at(7), type: EventType.telegramError, data: const {'error': 'x'}),
          HubEvent(
            seq: 17,
            ts: at(8),
            type: EventType.unlock,
            space: 'creativo',
            actor: 'bob',
            data: const {'durationMs': 7500000},
          ),
        ],
      );
    await pumpApp(t, s, size: const Size(1280, 1800));
    await t.tap(msButton('Tutta l\'attività'));
    await t.pump();
    expect(msText('Avventura: l\'app di carol non risponde'), findsOneWidget);
    expect(
      msTextContaining('La porta di Survival non è raggiungibile dall\'esterno'),
      findsOneWidget,
    );
    expect(
      msText('alice ha ripreso r.0.0.mca di Survival dalla #127 (nuova #130)'),
      findsOneWidget,
    );
    expect(msText('alice ha eliminato la #90 di Survival, liberati 3,0 MB'), findsOneWidget);
    expect(msText('alice ha reso bob admin'), findsOneWidget);
    expect(msTextContaining('La rete del gruppo non risponde'), findsOneWidget);
    expect(msTextContaining('Il bot Telegram'), findsOneWidget);
    expect(msText('bob ha chiuso Creativo dopo 2 h 05 min'), findsOneWidget);
    final badges = t.widgetList<MsBadge>(find.byType(MsBadge)).toList();
    MsBadgeKind kindOf(String label) => badges.firstWhere((b) => b.label == label).kind;
    // il colore solo dove serve: avvisi e problemi, il resto neutro
    expect(kindOf('non risponde'), MsBadgeKind.disk);
    expect(kindOf('porta'), MsBadgeKind.force);
    expect(kindOf('ripristino'), MsBadgeKind.restore);
    expect(kindOf('membri'), MsBadgeKind.neutral);
  });

  test('testi degli eventi nuovi anche in inglese', () {
    final s = AppStrings(Lang.en);
    String text(String type, Map<String, Object?> data, {String? actor, String? space}) =>
        s.home.eventText(type, actor, space, data, s.fmt).map((p) => p.$1).join();
    expect(
      text(EventType.stale, const {'holder': 'carol'}, space: 'Avventura'),
      'Avventura: carol\'s app is not responding',
    );
    expect(
      text(EventType.port, const {'state': 'reachable'}, space: 'Survival'),
      'The port of Survival is reachable: friends can join',
    );
    expect(
      text(EventType.memberRole, const {'member': 'bob', 'role': 'member'}, actor: 'alice'),
      'alice made bob a member',
    );
    expect(
      text(
        EventType.lock,
        const {'action': 'play', 'tookOver': 'carol'},
        actor: 'alice',
        space: 'Avventura',
      ),
      'alice is playing on Avventura (was carol\'s)',
    );
    expect(
      text(
        EventType.lock,
        const {'action': 'play', 'tookOver': 'alice'},
        actor: 'alice',
        space: 'Avventura',
      ),
      'alice resumes Avventura',
    );
    final it = AppStrings(Lang.it);
    String testo(Map<String, Object?> data) => it.home
        .eventText(EventType.lock, 'alice', 'Avventura', data, it.fmt)
        .map((p) => p.$1)
        .join();
    expect(testo(const {'action': 'play'}), 'alice gioca su Avventura');
    expect(testo(const {'tookOver': 'carol'}), 'alice gioca su Avventura (era di carol)');
    expect(testo(const {'tookOver': 'alice'}), 'alice riprende Avventura');
    // lock per caricare le mod: non una partita
    expect(testo(const {'action': 'push'}), 'alice carica Avventura dall\'app');
    expect(s.home.eventBadge(EventType.ztnet), 'network');
    for (final type in EventType.all) {
      expect(s.home.eventBadge(type), isNotEmpty);
      expect(AppStrings(Lang.it).home.eventBadge(type), isNotEmpty);
    }
  });

  testWidgets('home: golden', (t) async {
    await expectAppGolden(t, 'home', homeState(), size: const Size(1280, 1400));
  });

  testWidgets('home vuota: golden', (t) async {
    final s = testState(setup: (s) => s.debugSet(spaces: const []));
    await expectAppGolden(t, 'home_empty', s);
  });

  testWidgets('home offline, tema chiaro: golden', (t) async {
    final s = homeState(fullDisk: false);
    s.config.prefs['theme'] = 'light';
    s.debugSet(
      connection: Connection.offline,
      offlineSince: sampleNow.subtract(const Duration(seconds: 40)),
    );
    await expectAppGolden(t, 'home_offline_light', s, size: const Size(1280, 1400), dprs: [1.0]);
  });
}
