// Catalogo dei modpack nella procedura «Nuovo server»: elenco subito
// all'apertura, pagine, ricerca con la pausa, filtri che ricominciano
// l'elenco, dettagli con le versioni, modpack solo per i giocatori diviso fra
// server e giocatori, errore con «Riprova», golden. Modrinth è finto (risposte
// nella forma dell'API v2 scritte a mano), mai la rete vera.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/screens/pack_browser.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_ui/ms_ui.dart';

import 'home_test.dart' show homeSpaces;
import 'support/app_harness.dart';
import 'support/finders.dart';
import 'support/modpack_fakes.dart';
import 'support/space_fakes.dart';

// --- un Modrinth finto con tanti modpack ------------------------------------------------

const _names = [
  'Pixel Quest',
  'Sky Islands',
  'Iron Frontier',
  'Cozy Farms',
  'Deep Caves',
  'Star Forge',
  'Tiny Kingdoms',
  'Ocean Depths',
];

String packId(int i) => 'pack${i.toString().padLeft(4, '0')}';

Map<String, Object?> packHit(int i, {bool clientOnly = false}) => {
  'project_id': packId(i),
  'project_type': 'modpack',
  'slug': 'pack-$i',
  'author': const ['alice', 'bob', 'carol'][i % 3],
  'title': i < _names.length ? _names[i] : 'Modpack $i',
  'description': i == 0
      ? 'Catch, train and battle in a world full of adventures and new structures.'
      : 'A hand-made modpack number $i with quests and new biomes.',
  'categories': [
    const ['fabric', 'neoforge', 'quilt', 'forge'][i % 4],
    'adventure',
  ],
  'versions': ['1.20.1', if (i % 2 == 0) '1.21.1'],
  'downloads': 4200000 ~/ (i + 1),
  'icon_url': null,
  'client_side': 'required',
  'server_side': clientOnly || i == 0 ? 'unsupported' : 'required',
  'date_modified': '2026-10-01T12:00:00Z',
};

/// Un `.mrpack` di prova: due mod per tutti, una solo client (env), una
/// senza env che Modrinth sa solo client, una senza env sconosciuta.
Uint8List samplePack() {
  MrpackFile file(String name, {MrpackEnv? env, String project = 'modxxxxx'}) {
    final b = fakeJar(name);
    return MrpackFile(
      path: 'mods/$name',
      sha1: sha1Of(b),
      sha512: sha512Of(b),
      size: b.length,
      downloads: ['https://cdn.modrinth.com/data/$project/versions/vers0001/$name'],
      env: env,
    );
  }

  const both = MrpackEnv(MrEnv.required, MrEnv.required);
  const client = MrpackEnv(MrEnv.required, MrEnv.unsupported);
  final index = MrpackIndex(
    versionId: '1.8.0',
    name: 'Pixel Quest',
    files: [
      file('pokeworld.jar', env: both, project: 'pokewrld'),
      file('structures.jar', env: both, project: 'structur'),
      file('sodium.jar', env: client, project: 'sodiumxx'),
      file('minimap.jar', project: 'minimapx'),
      file('mystery.jar', project: 'mysteryx'),
    ],
    dependencies: const {'minecraft': '1.21.1', 'fabric-loader': '0.16.14'},
  );
  final plan = ClientPackPlan(
    pack: Pack(
      name: 'Pixel Quest',
      mcVersion: '1.21.1',
      loader: Loader.fabric,
      loaderVersion: '0.16.14',
    ),
    index: index,
    overrides: const [],
    missing: const [],
    modsZip: const [],
  );
  return writeMrpack(plan, (_) => null);
}

Map<String, Object?> packVersion(
  String id, {
  required String number,
  String type = 'release',
  String date = '2026-10-01T00:00:00Z',
  List<String> game = const ['1.21.1'],
  List<String> loaders = const ['fabric'],
  Uint8List? bytes,
}) {
  final b = bytes ?? utf8.encode('mrpack:$id');
  return {
    'id': id,
    'project_id': packId(0),
    'author_id': 'author01',
    'featured': false,
    'name': 'Pixel Quest $number',
    'version_number': number,
    'changelog': '',
    'dependencies': <Object?>[],
    'game_versions': game,
    'version_type': type,
    'loaders': loaders,
    'status': 'listed',
    'date_published': date,
    'downloads': 10,
    'files': [
      {
        'hashes': {'sha1': sha1Of(b), 'sha512': sha512Of(b)},
        'url': 'https://cdn.modrinth.com/data/${packId(0)}/versions/$id/pixel-quest-$number.mrpack',
        'filename': 'pixel-quest-$number.mrpack',
        'primary': true,
        'size': b.length,
        'file_type': null,
      },
    ],
  };
}

final class PackModrinth {
  PackModrinth({this.count = 45});

  final int count;
  final searches = <Map<String, String>>[];
  final pack = samplePack();
  bool offline = false;

  late final versions = [
    packVersion('verBeta1', number: '1.9.0-beta', type: 'beta', date: '2026-11-01T00:00:00Z'),
    packVersion('verRel18', number: '1.8.0', bytes: pack),
    packVersion(
      'verRel17',
      number: '1.7.2',
      date: '2026-06-01T00:00:00Z',
      game: ['1.20.1'],
      loaders: ['fabric', 'quilt'],
    ),
  ];

  late final transport = FakeTransport({
    'GET api.modrinth.com/v2/search': (r) {
      if (offline) throw HttpUnavailable(r.url, 'offline');
      final q = r.url.queryParameters;
      searches.add(q);
      final off = int.parse(q['offset']!), lim = int.parse(q['limit']!);
      final text = (q['query'] ?? '').toLowerCase();
      final all = [
        for (var i = 0; i < count; i++)
          if (text.isEmpty || '${packHit(i)['title']}'.toLowerCase().contains(text)) packHit(i),
      ];
      return jsonRes({
        'hits': all.skip(off).take(lim).toList(),
        'offset': off,
        'limit': lim,
        'total_hits': all.length,
      });
    },
    'GET api.modrinth.com/v2/tag/game_version': (_) => jsonRes([
      for (final v in ['1.21.1', '1.21', '1.20.1', '24w10a'])
        {'version': v, 'version_type': v.contains('w') ? 'snapshot' : 'release', 'major': false},
    ]),
    'GET api.modrinth.com/v2/project/${packId(0)}/version': (_) => jsonRes(versions),
    'GET api.modrinth.com/v2/project/${packId(0)}': (_) => jsonRes({
      ...projectJson(packId(0), title: 'Pixel Quest', server: 'unsupported'),
      'project_type': 'modpack',
      'slug': 'pack-0',
      'body':
          '# Welcome\nCatch, train and battle.\n\n## Features\n- 150 new structures\n- Custom quests\n\nJoin the [community](https://example.org/community).',
      'source_url': 'https://example.org/source',
    }),
    'POST api.modrinth.com/v2/version_files': (_) => jsonRes(<String, Object?>{}),
    'GET api.modrinth.com/v2/projects': (r) {
      final ids = (jsonDecode(r.url.queryParameters['ids']!) as List).cast<String>();
      final known = {
        'pokewrld': projectJson('pokewrld', title: 'Poke World'),
        'structur': projectJson('structur', title: 'Structures'),
        'sodiumxx': projectJson('sodiumxx', title: 'Sodium', server: 'unsupported'),
        'minimapx': projectJson('minimapx', title: 'Minimap', server: 'unsupported'),
      };
      return jsonRes([for (final i in ids) ?known[i]]);
    },
    'GET cdn.modrinth.com/*': (r) {
      for (final v in versions) {
        final f = (v['files']! as List).cast<Map<String, Object?>>().single;
        if (f['url'] == r.url.toString()) {
          final id = v['id']! as String;
          return HttpRes.bytes(200, id == 'verRel18' ? pack : utf8.encode('mrpack:$id'));
        }
      }
      return jsonRes({'error': 'not_found'}, status: 404);
    },
  });
}

/// Lo stato dell'app con l'ambiente del modpack su [m].
AppState packApp(PackModrinth m, {void Function(AppState)? setup}) {
  final worlds = Directory.systemTemp.createTempSync('ms_pack_worlds');
  addTearDown(() => worlds.deleteSync(recursive: true));
  return testState(
    modpack: fakeModpackEnv(transport: m.transport),
    prefs: {'worldsDir': worlds.path},
    setup: (s) {
      s.debugSet(spaces: homeSpaces(), route: const NewServerRoute());
      s.newServer
        ..name = 'Avventura'
        ..origin = NsOrigin.modpack;
      setup?.call(s);
    },
  );
}

/// Testo disegnato a pixel (etichette dei segmenti).
Finder pixelText(String t) =>
    find.byWidgetPredicate((w) => w is PixelText && w.text == t, description: 'pixel "$t"');

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 10));

// --- dati per i golden (senza rete) ------------------------------------------------------

List<MrSearchHit> sampleHits([int n = 8]) => [
  for (var i = 0; i < n; i++) MrSearchHit.fromJson(packHit(i)),
];

void main() {
  setUpAll(loadFonts);

  group('controller', () {
    test('apertura: i più scaricati senza cercare, poi le pagine dopo', () async {
      final m = PackModrinth();
      final s = packApp(m);
      final c = s.newServer..go(NsStep.modpack);
      final b = c.browser;
      expect(b.loading, isTrue);
      await settle();
      expect(b.hits, hasLength(20));
      expect(b.total, 45);
      expect(b.mcVersions, ['1.21.1', '1.21', '1.20.1']);
      final q = m.searches.single;
      expect(q['index'], 'downloads');
      expect(q.containsKey('query'), isFalse);
      expect(jsonDecode(q['facets']!), [
        ['project_type:modpack'],
      ]);
      await b.loadMore();
      await b.loadMore();
      expect(b.hits, hasLength(45));
      expect(b.hasMore, isFalse);
      expect(m.searches.map((q) => q['offset']), ['0', '20', '40']);
      expect(b.hits.map((h) => h.projectId).toSet(), hasLength(45));
      await b.loadMore(); // niente altro da caricare
      expect(m.searches, hasLength(3));
    });

    test('ricerca con la pausa: un solo invio dopo l\'ultimo tasto', () async {
      final m = PackModrinth();
      final b = packApp(m).newServer.browser..open();
      await settle();
      b
        ..setQuery('s')
        ..setQuery('sk')
        ..setQuery('sky');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(m.searches, hasLength(1)); // ancora in pausa
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(m.searches, hasLength(2));
      expect(m.searches.last['query'], 'sky');
      expect(b.hits.single.title, 'Sky Islands');
      // con il testo la rilevanza è un ordine vero
      b.setSort(PackSort.relevance);
      await settle();
      expect(m.searches.last['index'], 'relevance');
    });

    test('un filtro nuovo ricomincia l\'elenco dalla prima pagina', () async {
      final m = PackModrinth();
      final b = packApp(m).newServer.browser..open();
      await settle();
      await b.loadMore();
      expect(b.hits, hasLength(40));
      b.setLoader(Loader.fabric);
      expect(b.hits, isEmpty);
      expect(b.loading, isTrue);
      await settle();
      expect(b.hits, hasLength(20));
      final q = m.searches.last;
      expect(q['offset'], '0');
      expect(jsonDecode(q['facets']!), [
        ['project_type:modpack'],
        ['categories:fabric'],
      ]);
      b.setMcVersion('1.21.1');
      await settle();
      expect(jsonDecode(m.searches.last['facets']!), [
        ['project_type:modpack'],
        ['versions:1.21.1'],
        ['categories:fabric'],
      ]);
      b.setSort(PackSort.updated);
      await settle();
      expect(m.searches.last['index'], 'updated');
    });

    test('scelta: dettagli e versioni, proposta l\'ultima release; beta a richiesta', () async {
      final m = PackModrinth();
      final b = packApp(m).newServer.browser..open();
      await settle();
      await b.select(b.hits.first);
      expect(b.project!.body, startsWith('# Welcome'));
      expect(b.versions!.map((v) => v.versionNumber), ['1.9.0-beta', '1.8.0', '1.7.2']);
      expect(b.version!.versionNumber, '1.8.0');
      expect(b.visibleVersions.map((v) => v.versionNumber), ['1.8.0', '1.7.2']);
      b.setShowBeta(true);
      expect(b.visibleVersions, hasLength(3));
      b
        ..chooseVersion(b.versions!.first)
        ..setShowBeta(false);
      expect(b.version!.versionNumber, '1.8.0');
      // con un filtro Quilt la proposta è la release compatibile
      b.loader = Loader.quilt;
      expect(b.defaultVersion(b.versions!)!.versionNumber, '1.7.2');
    });

    test('modpack solo per i giocatori: server costruito togliendo le mod solo client', () async {
      final m = PackModrinth();
      final c = packApp(m).newServer..go(NsStep.modpack);
      final b = c.browser;
      await settle();
      await b.select(b.hits.first);
      await c.usePack();
      expect(c.importError, isNull);
      final sp = c.split!;
      expect(c.packClientOnly, isTrue);
      expect(sp.onServer.map((e) => e.name), ['Poke World', 'Structures']);
      expect(sp.clientOnly.map((e) => e.name), ['Minimap', 'Sodium']);
      expect(sp.unknown.map((e) => e.mod.file), ['mystery.jar']);
      expect((sp.serverCount(c.excludedUnknown), sp.clientCount(c.excludedUnknown)), (3, 2));
      final key = sp.unknown.single.key;
      c.keepUnknownOnServer(key, false);
      expect((sp.serverCount(c.excludedUnknown), sp.clientCount(c.excludedUnknown)), (2, 3));
      final imp = c.serverImport!;
      expect(imp.pack.byPath('mods/mystery.jar')!.side, PackSide.client);
      expect(imp.pack.byPath('mods/minimap.jar')!.location, 'client-overrides/mods/minimap.jar');
      expect(imp.pack.byPath('mods/pokeworld.jar')!.side, PackSide.both);
      expect(c.targetMc, '1.21.1');
      expect(c.packVersion!.versionNumber, '1.8.0');
      // il .mrpack scaricato non resta in giro
      expect(
        Directory(c.app.worldsDir).listSync().where((e) => e.path.endsWith('.mrpack')),
        isEmpty,
      );
      c.changePack();
      expect((c.imported, c.split), (null, null));
    });

    test('Modrinth non risponde: errore e poi «Riprova»', () async {
      final m = PackModrinth()..offline = true;
      final b = packApp(m).newServer.browser..open();
      await settle();
      expect(b.error, isA<ModrinthUnavailable>());
      expect(b.hits, isEmpty);
      m.offline = false;
      await b.reload();
      expect((b.error, b.hits.length), (null, 20));
    });
  });

  test('icone: una richiesta per URL, cache in memoria e su disco, errori ricordati', () async {
    final png = utf8.encode('icon-bytes');
    var calls = 0;
    final t = FakeTransport({
      'GET cdn.modrinth.com/data/pack0000/icon.png': (_) {
        calls++;
        return HttpRes.bytes(200, png);
      },
    });
    final dir = Directory.systemTemp.createTempSync('ms_icons');
    addTearDown(() => dir.deleteSync(recursive: true));
    const url = 'https://cdn.modrinth.com/data/pack0000/icon.png';
    final icons = IconCache(t, userAgent: 'test', dir: dir.path);
    final r = await Future.wait([icons.load(url), icons.load(url)]);
    expect(r.map((b) => utf8.decode(b!)), ['icon-bytes', 'icon-bytes']);
    expect(calls, 1);
    expect(t.requests.single.headers['User-Agent'], 'test');
    expect(icons.peek(url), isNotNull);
    // un'altra istanza la trova su disco
    final again = IconCache(t, userAgent: 'test', dir: dir.path);
    expect(utf8.decode((await again.load(url))!), 'icon-bytes');
    expect(calls, 1);
    // 404 e indirizzi non https: disegno di riserva, senza riprovare
    expect(await icons.load('https://cdn.modrinth.com/data/missing/icon.png'), isNull);
    expect(icons.failed('https://cdn.modrinth.com/data/missing/icon.png'), isTrue);
    expect(await icons.load('http://example.org/icon.png'), isNull);
    expect(await icons.load('file:///etc/passwd'), isNull);
    expect(t.requests, hasLength(2));
  });

  test('compareMc e latestMc', () {
    expect(latestMc(['1.20.1', '1.21.11', '1.21.4', '1.9']), '1.21.11');
    expect(latestMc(['1.21.11', '26.1']), '26.1');
    expect(latestMc(const []), isNull);
    expect(compareMc('1.21', '1.21.0'), 0);
  });

  group('schermata', () {
    testWidgets('«Da un modpack»: l\'elenco c\'è subito, senza cercare', (t) async {
      final m = PackModrinth();
      final s = packApp(m);
      s.newServer.go(NsStep.modpack);
      await pumpApp(t, s);
      await t.pump();
      expect(pixelText('Sfoglia Modrinth'), findsOneWidget);
      expect(msText('45 modpack'), findsOneWidget);
      expect(find.byType(PackRow), findsWidgets);
      expect(msTextContaining('Pixel Quest'), findsWidgets);
      expect(
        msText('Scegli un modpack dall\'elenco per vederne descrizione e versioni.'),
        findsOneWidget,
      );
    });

    testWidgets('la ricerca parte da sola dopo la pausa', (t) async {
      final m = PackModrinth();
      final s = packApp(m);
      s.newServer.go(NsStep.modpack);
      await pumpApp(t, s);
      await t.pump();
      await t.enterText(find.byType(EditableText).first, 'deep');
      await t.pump(const Duration(milliseconds: 100));
      expect(m.searches, hasLength(1));
      await t.pump(const Duration(milliseconds: 250));
      await t.pump();
      expect(m.searches.last['query'], 'deep');
      expect(msText('1 modpack'), findsOneWidget);
    });

    testWidgets('scelta di un modpack: dettagli, versione, link nel browser', (t) async {
      final m = PackModrinth();
      final s = packApp(m);
      s.newServer.go(NsStep.modpack);
      await pumpApp(t, s);
      await t.pump();
      await t.tap(find.byType(PackRow).first);
      await t.pump();
      await t.pump();
      expect(msButton('Usa questo modpack'), findsOneWidget);
      expect(msText('Welcome'), findsOneWidget);
      expect(msText('•  150 new structures'), findsOneWidget);
      await t.ensureVisible(msButton('community'));
      await t.pump();
      await t.tap(msButton('community'));
      await t.pump();
      expect((s.modpackEnv.tools as FakeTools).opened, ['https://example.org/community']);
    });

    testWidgets('riepilogo: le mod senza indicazioni si tolgono dal server con un clic', (t) async {
      final m = PackModrinth();
      final s = packApp(m);
      final c = s.newServer..go(NsStep.modpack);
      await t.runAsync(() async {
        await settle();
        await c.browser.select(c.browser.hits.first);
        await c.usePack();
      });
      c.debugSet(javas: sampleJavas);
      await pumpApp(t, s, size: const Size(1280, 1200));
      expect(
        msText('3 mod sul server, 2 solo per i giocatori (esclusi dal server)'),
        findsOneWidget,
      );
      expect(msText('1 mod senza indicazioni: scelta manuale'), findsOneWidget);
      await t.tap(find.byType(MsCheckbox));
      await t.pump();
      expect(
        msText('2 mod sul server, 3 solo per i giocatori (esclusi dal server)'),
        findsOneWidget,
      );
      await t.tap(msButton('Vedi elenco'));
      await t.pump();
      expect(msText('Solo per i giocatori (2)'), findsOneWidget);
      expect(msText('Minimap'), findsOneWidget);
      await t.tap(msButton('Avanti'));
      await t.pump();
      expect(msText('2 sul server, 3 solo per i giocatori'), findsOneWidget);
    });

    testWidgets('file .mrpack: l\'altra strada nello stesso passo', (t) async {
      final s = packApp(PackModrinth());
      s.newServer.go(NsStep.modpack);
      await pumpApp(t, s);
      await t.pump();
      await t.tap(pixelText('Da un file .mrpack'), warnIfMissed: false);
      await t.pump();
      expect(s.newServer.packSource, NsPackSource.file);
      expect(find.byType(PackRow), findsNothing);
      expect(msButton('Apri'), findsOneWidget);
    });
  });

  group('golden', () {
    AppState goldenState({bool selected = false, bool error = false, bool summary = false}) {
      final m = PackModrinth();
      return packApp(
        m,
        setup: (s) {
          final c = s.newServer;
          c.debugSet(step: NsStep.modpack, javas: sampleJavas);
          final b = c.browser;
          b.debugSet(
            hits: error ? const [] : sampleHits(),
            total: error ? 0 : 1284,
            loading: false,
            mcVersions: const ['1.21.1', '1.21', '1.20.1'],
            error: error ? const ModrinthUnavailable('offline') : null,
          );
          if (selected || summary) {
            final vs = [for (final v in m.versions) MrVersion.fromJson(v)];
            b.debugSet(
              selected: b.hits.first,
              project: MrProject.fromJson({
                ...projectJson(packId(0), title: 'Pixel Quest', server: 'unsupported'),
                'project_type': 'modpack',
                'slug': 'pack-0',
                'body':
                    '# Welcome\nCatch, train and battle in a world full of adventures.\n\n## Features\n- 150 new structures\n- Custom quests and a starter kit\n\nJoin the [community](https://example.org/community).',
              }),
              versions: vs,
              version: vs[1],
            );
          }
          if (summary) {
            final imp = readMrpack(m.pack, name: 'Pixel Quest');
            c.debugSet(
              imported: imp,
              split: splitForServer(
                imp,
                projects: {
                  'minimapx': MrProject.fromJson(
                    projectJson('minimapx', title: 'Minimap', server: 'unsupported'),
                  ),
                  'pokewrld': MrProject.fromJson(projectJson('pokewrld', title: 'Poke World')),
                  'structur': MrProject.fromJson(projectJson('structur', title: 'Structures')),
                  'sodiumxx': MrProject.fromJson(
                    projectJson('sodiumxx', title: 'Sodium', server: 'unsupported'),
                  ),
                },
              ),
              packChosen: b.hits.first,
              packVersion: b.version,
            );
          }
        },
      );
    }

    testWidgets('catalogo', (t) async {
      await expectAppGolden(t, 'new_server_packs', goldenState());
    });
    testWidgets('dettagli con le versioni', (t) async {
      await expectAppGolden(t, 'new_server_pack_details', goldenState(selected: true));
    });
    testWidgets('modpack solo per i giocatori: riepilogo', (t) async {
      await expectAppGolden(
        t,
        'new_server_pack_split',
        goldenState(summary: true),
        size: const Size(1280, 1100),
        prepare: (t) async {
          if (msButton('Vedi elenco').evaluate().isNotEmpty) {
            await t.tap(msButton('Vedi elenco'));
            await t.pump();
          }
        },
      );
    });
    testWidgets('Modrinth non risponde', (t) async {
      await expectAppGolden(t, 'new_server_packs_error', goldenState(error: true));
    });
    testWidgets('finestra stretta: dettagli al posto dell\'elenco', (t) async {
      await expectAppGolden(
        t,
        'new_server_pack_narrow',
        goldenState(selected: true),
        size: const Size(900, 860),
      );
    });
  });
}
