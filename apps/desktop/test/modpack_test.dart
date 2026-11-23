// Scheda Mod e pacchetto per i giocatori: elenco con lati e stati,
// aggiornamenti (anche bloccati), ricerca, barra delle modifiche (libero, in
// gioco, Modrinth giù), cambio di versione con il controllo, pacchetto per i
// giocatori (vecchio, Prism mancante, vanilla), dialoghi e golden.
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/screens/modpack.dart';
import 'package:minesync_desktop/src/screens/modpack_dialogs.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:ms_minecraft/ms_minecraft.dart' show ServerLayout;
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_ui/ms_ui.dart';

import 'home_test.dart' show homeSpaces;
import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/modpack_fakes.dart';

PackMod mod(
  String name, {
  String? project,
  String version = '1.0.0',
  PackSide side = PackSide.both,
  bool optional = false,
  bool disabled = false,
  bool manual = false,
  bool auto = false,
  List<String> requires = const [],
  String? file,
}) {
  final f = file ?? '${name.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '-')}-$version.jar';
  final b = fakeJar(f);
  final pid =
      project ??
      name.toUpperCase().replaceAll(RegExp('[^A-Z]'), '').padRight(8, 'X').substring(0, 8);
  return PackMod(
    path: 'mods/$f',
    name: manual ? null : name,
    sha1: sha1Of(b),
    sha512: sha512Of(b),
    size: 1 << 20,
    side: side,
    optional: optional,
    disabled: disabled,
    auto: auto,
    source: manual ? PackSource.manual : PackSource.modrinth,
    projectId: manual ? null : pid,
    versionId: manual
        ? null
        : '${pid.substring(0, 4)}V${version.replaceAll('.', '')}'.padRight(8, '0').substring(0, 8),
    versionNumber: manual ? null : version,
    requires: requires,
    downloads: manual ? const [] : ['https://cdn.modrinth.com/data/$pid/versions/x/$f'],
  );
}

final fabricApi = mod('Fabric API', project: 'P7dR8mSH', version: '0.116.6', auto: true);
final create = mod('Create', version: '6.0.6', requires: ['P7dR8mSH']);
final sodium = mod('Sodium', version: '0.6.13', side: PackSide.client, optional: true);
final iris = mod('Iris Shaders', version: '1.8.8', side: PackSide.client, optional: true);
final lithium = mod('Lithium', version: '0.15.0');
final jade = mod('Jade', version: '15.10.0', requires: ['P7dR8mSH']);
final chunky = mod('Chunky', version: '1.4.27', side: PackSide.server);
final xaero = mod('Xaeros Minimap', version: '25.2.10', side: PackSide.client);
final tweaks = mod(
  'survival-tweaks',
  manual: true,
  side: PackSide.server,
  file: 'survival-tweaks.jar',
);

Pack basePack({String name = 'Creativo'}) => Pack(
  name: name,
  mcVersion: '1.21.1',
  loader: Loader.fabric,
  loaderVersion: '0.16.14',
  mods: [fabricApi, create, sodium, iris, lithium, jade, chunky, xaero, tweaks],
);

Pack draftPack(Pack b) {
  final farmers = mod('Farmers Delight Refabricated', version: '3.2.3');
  return b.withMods([
    farmers,
    b.byKey(lithium.key)!.copyWith(versionId: 'LITHV151', versionNumber: '0.15.1'),
    b.byKey(xaero.key)!.copyWith(disabled: true),
  ]);
}

MrVersion mrv(String project, String number, {String id = 'NEWVER01'}) => MrVersion(
  id: id,
  projectId: project,
  versionNumber: number,
  name: number,
  versionType: MrVersionType.release,
  gameVersions: const ['1.21.1'],
  loaders: const ['fabric'],
  featured: false,
  datePublished: 0,
  files: const [],
  dependencies: const [],
);

List<UpdateCheck> sampleUpdates(Pack b) => [
  UpdateCheck(
    mod: b.byKey(create.key)!,
    status: UpdateStatus.available,
    latest: mrv(create.projectId!, '6.0.8'),
  ),
  UpdateCheck(
    mod: b.byKey(jade.key)!,
    status: UpdateStatus.available,
    latest: mrv(jade.projectId!, '15.10.2'),
  ),
  UpdateCheck(
    mod: b.byKey(iris.key)!,
    status: UpdateStatus.blocked,
    latest: mrv(iris.projectId!, '1.9.0'),
    blockers: [
      Blocker(
        BlockReason.dependencyIncompatible,
        projectId: iris.projectId!,
        otherProjectId: sodium.projectId,
        gameVersions: const ['1.21.4'],
      ),
    ],
  ),
];

MrSearchHit hit(
  String id,
  String title, {
  List<String> cats = const ['fabric'],
  String author = 'someone',
}) => MrSearchHit.fromJson(hitJson(id, title: title, categories: cats, author: author));

const _layout = LocalScan(
  exists: true,
  layout: ServerLayout(
    workDir: '/tmp/mondi/creativo',
    label: 'Fabric',
    loader: 'fabric',
    loaderVersion: '0.16.14',
    mcVersion: '1.21.1',
  ),
);

/// Stato dell'app sulla scheda Mod di [space] con il pack pronto.
AppState modState({
  String space = 'creativo',
  bool client = false,
  bool dirty = true,
  bool modrinthDown = false,
  bool search = true,
  ApplyState? apply,
  bool? prism = true,
  ClientInstall? installed,
  Pack? pack,
  bool packIsNew = false,
}) => testState(
  setup: (s) {
    s.debugSet(
      spaces: homeSpaces(),
      route: ModpackRoute(space, client: client),
    );
    s.config.links[space] = '/tmp/mondi/$space';
    if (installed != null) s.config.prefs['modpack.client.$space'] = installed.toJson();
    final head = s.space(space)!.headN;
    s.spaceState(space).debugSet(baseN: head, scan: _layout);
    final b = pack ?? basePack(name: s.space(space)!.name);
    s
        .modpack(space)
        .debugSet(
          phase: PackPhase.ready,
          base: b,
          draft: dirty ? draftPack(b) : b,
          updates: pack == null ? sampleUpdates(b) : const [],
          updatesAt: DateTime.utc(2026, 11, 22, 17, 59),
          modrinthDown: modrinthDown,
          lastAttempt: DateTime.utc(2026, 11, 22, 18, 3),
          query: search ? 'waystones' : null,
          results: search && !modrinthDown
              ? [
                  SearchHitView(hit('WAYSTONE', 'Waystones', author: 'BlayTheNinth'), fits: true),
                  SearchHitView(hit('FABWAYST', 'Fabric Waystones'), fits: true),
                  SearchHitView(hit('BALMBALM', 'Balm'), fits: true, installed: true),
                  SearchHitView(
                    hit('MEKANISM', 'Mekanism', cats: const ['neoforge']),
                    fits: false,
                    loaders: const ['neoforge'],
                  ),
                ]
              : const [],
          applyState: apply,
          prismFound: prism,
          packIsNew: packIsNew,
        );
  },
);

const _big = Size(1280, 1500);

const serverTip = 'Solo sul server: i giocatori non la scaricano';
const clientTip = 'Solo per i giocatori: il server non la carica';

Finder _tag(String tip) =>
    find.byWidgetPredicate((w) => w is MsIconTag && w.tooltip == tip, description: tip);

void main() {
  setUpAll(loadFonts);
  tearDown(() => RetargetPanel.debugReport = null);

  testWidgets('elenco: lati, aggiunte a mano, nuove e nelle modifiche; schede del server', (
    t,
  ) async {
    await pumpApp(t, modState(), size: _big);
    // niente titolo grande né «gen #N»: la vista la dice il selettore
    expect(msText('Mod di Creativo'), findsNothing);
    expect(msTextContaining('gen #'), findsNothing);
    // un solo modo per aggiungere: il pannello di Modrinth con il file a parte
    expect(msButton('Da file…'), findsOneWidget);
    expect(msButton('Pacchetto per i giocatori'), findsNothing);
    // filtri: tutte, le due eccezioni di lato, disattivate
    final filters = t.widget<MsSegmented<ModFilter>>(find.byType(MsSegmented<ModFilter>));
    expect(filters.segments.map((s) => s.label.split(' ').first), [
      'Tutte',
      'Solo',
      'Solo',
      'Disattivate',
    ]);
    expect(filters.segments[1].label, 'Solo server 2');
    expect(filters.segments[2].label, 'Solo giocatori 3');
    // «server e giocatori» è il caso normale: niente segnale, solo le eccezioni
    expect(_tag(serverTip), findsNWidgets(2));
    expect(_tag(clientTip), findsNWidgets(3));
    // l'aiuto della barra sta nel tooltip della «i»
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is MsTooltip &&
            w.message ==
                'Valgono per tutti dal prossimo Gioca. Si può tornare indietro dalla Storia.',
      ),
      findsOneWidget,
    );
    expect(msText('Farmers Delight Refabricated'), findsWidgets);
    // nella riga lo stato; versione e file stanno nel dettaglio (pulsante «i»)
    expect(msTextContaining('nuova'), findsWidgets);
    expect(find.bySemanticsLabel('Dettaglio: Farmers Delight Refabricated'), findsOneWidget);
    expect(msText('aggiunto a mano'), findsOneWidget);
    expect(msTextContaining('Non trovato su Modrinth'), findsOneWidget);
    expect(msText('3 modifiche da applicare'), findsOneWidget);
    expect(msButton('Applica e carica sull\'hub'), findsOneWidget);
    // versione e loader in testa come etichette piatte
    expect(msMeta(['Minecraft 1.21.1', 'Fabric 0.16.14']), findsOneWidget);
  });

  testWidgets('finestra stretta: testa e barra delle modifiche vanno a capo senza uscire', (
    t,
  ) async {
    for (final space in ['creativo', 'survival']) {
      await pumpApp(t, modState(space: space), size: const Size(700, 900));
      expect(t.takeException(), isNull);
      expect(msText('3 modifiche da applicare'), findsOneWidget);
    }
  });

  testWidgets('filtro «Solo server»: solo le mod che i giocatori non scaricano', (t) async {
    await pumpApp(t, modState(dirty: false, search: false), size: _big);
    t.widget<MsSegmented<ModFilter>>(find.byType(MsSegmented<ModFilter>)).onChanged!(
      ModFilter.server,
    );
    await t.pump();
    expect(msText('Chunky'), findsOneWidget);
    expect(msText('survival-tweaks.jar'), findsOneWidget);
    expect(msText('Lithium'), findsNothing);
    expect(msText('Sodium'), findsNothing);
  });

  testWidgets('dettaglio: dialogo dal pulsante «i» e dalla riga, Esc chiude', (t) async {
    final s = modState(dirty: false, search: false);
    await pumpApp(t, s, size: _big);
    await t.tap(find.bySemanticsLabel('Dettaglio: Chunky'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MsDialog), findsOneWidget);
    expect(msText('Chunky'), findsWidgets);
    expect(msText('Modrinth'), findsOneWidget);
    expect(msText(RegExp(r'^1[,.]?0? MB$')), findsOneWidget);
    expect(msButton('Apri su Modrinth'), findsOneWidget);
    expect(msText('Le modifiche vanno nell\'elenco da applicare.'), findsOneWidget);
    // selettore con le icone dei lati, nell'ordine server · entrambi · giocatori
    final side = t.widget<MsSegmented<PackSide>>(find.byType(MsSegmented<PackSide>));
    expect(side.segments.map((s) => s.label), ['Server', 'Server e giocatori', 'Giocatori']);
    expect(side.segments.every((s) => s.icon != null), isTrue);
    // le modifiche si vedono subito nel dialogo
    side.onChanged!(PackSide.both);
    await t.pump();
    expect(s.modpack('creativo').draft!.byKey(chunky.key)!.side, PackSide.both);
    expect(
      t.widget<MsSegmented<PackSide>>(find.byType(MsSegmented<PackSide>)).value,
      PackSide.both,
    );
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MsDialog), findsNothing);
    // anche la riga apre il dettaglio
    await t.tap(msText('Lithium'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MsDialog), findsOneWidget);
    expect(msText('0.15.0'), findsOneWidget);
    await t.tap(msButton('Chiudi'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MsDialog), findsNothing);
  });

  testWidgets('dettaglio: «Rimuovi…» chiude il dettaglio prima di chiedere conferma', (t) async {
    final s = modState(dirty: false, search: false);
    await pumpApp(t, s, size: _big);
    await t.tap(find.bySemanticsLabel('Dettaglio: Fabric API'));
    await t.pump(const Duration(milliseconds: 400));
    await t.tap(msButton('Rimuovi…'));
    await t.pump(const Duration(milliseconds: 400));
    // mai due dialoghi uno sopra l'altro
    expect(find.byType(MsDialog), findsOneWidget);
    expect(msText('Rimuovere Fabric API?'), findsOneWidget);
    await t.tap(msButton('Rimuovi Fabric API e 2 mod'));
    await t.pump(const Duration(milliseconds: 400));
    expect(s.modpack('creativo').draft!.byKey(fabricApi.key), isNull);
    expect(find.byType(MsDialog), findsNothing);
  });

  testWidgets('dettaglio: si chiude da solo se la mod sparisce', (t) async {
    final s = modState(search: false);
    await pumpApp(t, s, size: _big);
    await t.tap(find.bySemanticsLabel('Dettaglio: Farmers Delight Refabricated'));
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MsDialog), findsOneWidget);
    s.modpack('creativo').discard();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(MsDialog), findsNothing);
  });

  testWidgets('in gioco: dettaglio in sola lettura per lato e rimozione', (t) async {
    await pumpApp(t, modState(space: 'survival', search: false), size: _big);
    await t.tap(find.bySemanticsLabel('Dettaglio: Chunky'));
    await t.pump(const Duration(milliseconds: 400));
    expect(t.widget<MsSegmented<PackSide>>(find.byType(MsSegmented<PackSide>)).onChanged, isNull);
    expect(t.widget<MsButton>(msButton('Rimuovi…')).onPressed, isNull);
  });

  testWidgets('segnali di lato: tooltip anche al passaggio del mouse', (t) async {
    await pumpApp(t, modState(dirty: false, search: false), size: _big);
    final tag = _tag(serverTip).first;
    await t.ensureVisible(tag);
    await t.pump();
    final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(t.getCenter(tag));
    await t.pump(MsDuration.d4);
    expect(find.byType(MsTooltipBubble), findsOneWidget);
  });

  testWidgets('aggiornamenti: «Aggiorna tutte» e «Perché?» per quello bloccato', (t) async {
    final s = modState(dirty: false);
    await pumpApp(t, s, size: _big);
    expect(msButton('Aggiorna tutte (2)'), findsOneWidget);
    await t.tap(msButton('Motivo'));
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('Iris Shaders 1.9.0 non si può installare'), findsOneWidget);
    await t.tap(msButton('Nascondi questo aggiornamento'));
    await t.pump(const Duration(milliseconds: 400));
    expect(s.modpack('creativo').draft!.byKey(iris.key)!.pinned, isTrue);
  });

  testWidgets('spegnere e togliere: rimozione con il dialogo delle dipendenti', (t) async {
    final s = modState(dirty: false, search: false);
    await pumpApp(t, s, size: _big);
    final mp = s.modpack('creativo');
    await t.tap(find.bySemanticsLabel('Rimuovi: Fabric API'));
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('Rimuovere Fabric API?'), findsOneWidget);
    await t.tap(msButton('Rimuovi Fabric API e 2 mod'));
    await t.pump(const Duration(milliseconds: 400));
    expect(mp.draft!.byKey(create.key), isNull);
    expect(mp.changes!.removed, hasLength(3));
  });

  testWidgets('in gioco: interruttori spenti, Applica rifiutato con l\'opzione della coda', (
    t,
  ) async {
    final s = modState(space: 'survival');
    await pumpApp(t, s, size: _big);
    expect(msText('bob sta giocando: le mod sono in sola lettura'), findsOneWidget);
    expect(msButton('Applica quando bob chiude'), findsOneWidget);
    await t.ensureVisible(msButton('Applica e carica sull\'hub'));
    await t.tap(msButton('Applica e carica sull\'hub'));
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('bob sta giocando su Survival'), findsOneWidget);
    await t.tap(msButton('Attendi'));
    await t.pump(const Duration(milliseconds: 400));
    expect(s.modpack('survival').queued, isTrue);
    expect(msButton('Togli dalla coda'), findsOneWidget);
  });

  testWidgets('libero: Applica chiede conferma con il riepilogo', (t) async {
    await pumpApp(t, modState(), size: _big);
    await t.ensureVisible(msButton('Applica e carica sull\'hub'));
    await t.tap(msButton('Applica e carica sull\'hub'));
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('Caricare le modifiche sull\'hub?'), findsOneWidget);
    expect(
      msText('Valgono per tutti: chi gioca Creativo da adesso trova le mod nuove.'),
      findsOneWidget,
    );
    expect(msText('~ Lithium 0.15.0 › 0.15.1'), findsWidgets);
  });

  testWidgets('cambio di loader: conferma pericolosa prima di togliere le mod', (t) async {
    final s = modState(dirty: false, search: false);
    final b = s.modpack('creativo').base!;
    RetargetPanel.debugReport = _report(b);
    await pumpApp(t, s, size: _big);
    await t.tap(msButton('Cambia versione o loader…'));
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('Controllo delle 9 mod completato'), findsOneWidget);
    await t.tap(msButton('Cambia e rimuovi 2 mod…'));
    await t.pump(const Duration(milliseconds: 400));
    expect(msText('Passare Creativo a NeoForge?'), findsOneWidget);
    await t.tap(msButton('Passa a NeoForge'));
    await t.pump(const Duration(milliseconds: 400));
    expect(s.modpack('creativo').draft!.loader, Loader.neoforge);
  });

  testWidgets('pacchetto per i giocatori: facoltative per questo PC, Prism, profilo', (t) async {
    final s = modState(
      client: true,
      dirty: false,
      installed: const ClientInstall(target: 'prism', n: 54),
    );
    await pumpApp(t, s, size: _big);
    expect(t.widget<MsSegmented<bool>>(find.byType(MsSegmented<bool>).first).value, isTrue);
    expect(
      msText('Il tuo pacchetto in Prism Launcher è alla #54, il server alla #57'),
      findsOneWidget,
    );
    expect(msText('Sodium'), findsOneWidget);
    // anche qui solo le eccezioni di lato, con il tooltip
    expect(_tag(clientTip), findsWidgets);
    expect(_tag(serverTip), findsWidgets);
    final box = find.byWidgetPredicate((w) => w is MsCheckbox && w.label == 'includi').first;
    await t.ensureVisible(box);
    await t.pump();
    await t.tap(box);
    await t.pump();
    expect(s.modpack('creativo').chosenOptional, isNot(contains(iris.key)));
  });

  testWidgets('pacchetto non ancora creato: si torna alle mod del server', (t) async {
    final s = modState(client: true, dirty: false, packIsNew: true);
    await pumpApp(t, s, size: _big);
    expect(msText('Ancora nessun pacchetto'), findsOneWidget);
    expect(msText('Applica una volta le mod del server per crearlo.'), findsOneWidget);
    await t.tap(msButton('Vai alle mod del server'));
    await t.pump();
    expect(s.route, const ModpackRoute('creativo'));
  });

  testWidgets('prima volta: avviso solo per le mod non trovate, niente file interni', (t) async {
    final s = modState(dirty: false, search: false, packIsNew: true);
    await pumpApp(t, s, size: _big);
    // non più un avviso in cima: una riga sotto i filtri di «Installate»
    expect(msText('Le mod non trovate su Modrinth restano come sono.'), findsOneWidget);
    expect(find.byType(MsAlert), findsNothing);
    expect(msTextContaining('minesync-pack'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is MsMeta && w.items.any((i) => i.contains('minesync-pack'))),
      findsNothing,
    );
    expect(
      find.byWidgetPredicate(
        (w) => w is MsMeta && w.items.contains('Prima configurazione delle mod'),
      ),
      findsOneWidget,
    );
  });

  group('golden', () {
    testWidgets('scheda Mod con modifiche e ricerca', (t) async {
      await expectAppGolden(t, 'modpack_mods', modState(), size: _big);
    });

    testWidgets('scheda Mod in gioco con Modrinth irraggiungibile', (t) async {
      await expectAppGolden(
        t,
        'modpack_locked',
        modState(space: 'survival', modrinthDown: true),
        size: _big,
      );
    });

    testWidgets('applicazione in corso', (t) async {
      await expectAppGolden(
        t,
        'modpack_applying',
        modState(
          search: false,
          apply: const Applying(
            'download',
            done: 3 << 20,
            total: 4 << 20,
            current: 'Farmers Delight',
          ),
        ),
      );
    });

    testWidgets('cambia versione o loader: controllo delle mod', (t) async {
      final s = modState(dirty: false, search: false);
      RetargetPanel.debugReport = _report(s.modpack('creativo').base!);
      var opened = false;
      await expectAppGolden(
        t,
        'modpack_retarget',
        s,
        size: _big,
        prepare: (t) async {
          if (opened) return;
          opened = true;
          await t.tap(msButton('Cambia versione o loader…'));
          await t.pump(const Duration(milliseconds: 400));
        },
      );
    });

    testWidgets('pacchetto per i giocatori, vecchio', (t) async {
      await expectAppGolden(
        t,
        'modpack_client',
        modState(
          client: true,
          dirty: false,
          installed: const ClientInstall(target: 'prism', n: 54),
        ),
        size: _big,
      );
    });

    testWidgets('pacchetto per i giocatori, Prism non trovato', (t) async {
      await expectAppGolden(
        t,
        'modpack_client_noprism',
        modState(client: true, dirty: false, prism: false),
      );
    });

    testWidgets('pacchetto per i giocatori, server vanilla', (t) async {
      await expectAppGolden(
        t,
        'modpack_client_vanilla',
        modState(
          client: true,
          dirty: false,
          pack: Pack(name: 'Creativo', mcVersion: '1.21.4', loader: Loader.vanilla),
        ),
      );
    });
  });

  group('dialoghi: golden', () {
    Future<void> dialog(
      WidgetTester t,
      String name,
      Future<Object?> Function(BuildContext) open,
    ) async {
      var opened = false;
      await expectAppGolden(
        t,
        'modpack_dialog_$name',
        modState(dirty: false, search: false),
        prepare: (t) async {
          if (opened) return;
          opened = true;
          unawaited(open(t.element(find.byType(MsSidebar))));
          await t.pump();
          await t.pump(const Duration(milliseconds: 400));
        },
      );
    }

    final b = basePack();
    final waystones = mod('Waystones', version: '21.1.25', requires: ['BALMBALM']);
    final balm = mod('Balm', project: 'BALMBALM', version: '21.0.46', auto: true);

    testWidgets('dipendenze', (t) async {
      await dialog(
        t,
        'add',
        (c) => showAddDialog(
          c,
          AddPlan(
            projectId: waystones.projectId!,
            mod: waystones,
            dependencies: [balm],
            satisfied: [fabricApi],
          ),
          name: 'Waystones',
          loader: Loader.fabric,
          mcVersion: '1.21.1',
        ),
      );
    });

    testWidgets('aggiornamento incompatibile', (t) async {
      await dialog(
        t,
        'blocked',
        (c) => showBlockedUpdateDialog(c, sampleUpdates(b)[2], name: (_) => 'Sodium'),
      );
    });

    testWidgets('cambio di loader', (t) async {
      await dialog(
        t,
        'loader',
        (c) => showLoaderChangeDialog(c, _report(b), server: 'Creativo', head: 57),
      );
    });

    testWidgets('CurseForge', (t) async {
      final cf = mod('Torri Antiche', manual: true, file: 'torri-antiche.jar').copyWith(
        name: 'Torri Antiche',
        source: PackSource.curseforge,
        curseforge: const CurseForgeRef(
          pageUrl: 'https://www.curseforge.com/minecraft/mc-mods/torri',
        ),
      );
      await dialog(
        t,
        'curseforge',
        (c) => showCurseForgeDialog(
          c,
          cf,
          root: '/tmp/mondi/creativo',
          loader: Loader.fabric,
          mcVersion: '1.21.1',
        ),
      );
    });

    testWidgets('applica mentre qualcuno gioca', (t) async {
      await dialog(
        t,
        'locked',
        (c) => showLockedApplyDialog(
          c,
          holder: 'bob',
          server: 'Survival',
          changes: 3,
          next: 129,
          since: '48 min',
          online: 2,
        ),
      );
    });

    testWidgets('applica e carica', (t) async {
      await dialog(
        t,
        'confirm',
        (c) => showApplyConfirmDialog(
          c,
          diff: PackDiff(b, draftPack(b)),
          server: 'Creativo',
          next: 58,
          head: 57,
        ),
      );
    });

    testWidgets('rimozione con le dipendenti', (t) async {
      await dialog(t, 'remove', (c) => showRemoveDialog(c, planRemove(b, fabricApi.key)));
    });

    testWidgets('dettaglio di una mod', (t) async {
      await dialog(
        t,
        'detail',
        (c) => showModDetailDialog(c, AppStateScope.read(c).modpack('creativo'), sodium.key),
      );
    });

    testWidgets('dettaglio di una mod aggiunta a mano', (t) async {
      await dialog(
        t,
        'detail_manual',
        (c) => showModDetailDialog(c, AppStateScope.read(c).modpack('creativo'), tweaks.key),
      );
    });
  });
}

/// Controllo per NeoForge: tutte pronte tranne Sodium e Iris; la mod a mano
/// da controllare.
CompatReport _report(Pack b) => CompatReport(
  from: b,
  target: const PackTarget('1.21.1', Loader.neoforge),
  loaderVersion: '21.1.172',
  entries: [
    for (final m in b.mods)
      if (m.source == PackSource.manual)
        ModCompat(mod: m, status: CompatStatus.manual)
      else if (m.key == sodium.key || m.key == iris.key)
        ModCompat(
          mod: m,
          status: CompatStatus.blocked,
          blockers: [Blocker(BlockReason.noCompatibleVersion, projectId: m.projectId!)],
        )
      else
        ModCompat(mod: m, status: CompatStatus.ready, next: m),
  ],
);
