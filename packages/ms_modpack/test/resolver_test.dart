// Risolutore: aggiungere con dipendenze, aggiornare con i motivi dei
// blocchi, togliere con le dipendenti, cambiare versione o loader. Dati
// inventati nella forma dell'API v2 di Modrinth.
import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  // Fabric API c'è già; Waystones chiede Balm (da aggiungere) e Fabric API
  final fapi = v('fapiV1', 'fabricApi', '0.116.6', day: 1);
  final fapi2 = v('fapiV2', 'fabricApi', '0.116.9', day: 9);
  final balm = v('balmV1', 'balmPr', '21.0.46', day: 5, deps: [dep('fabricApi')]);
  final balmOld = v('balmV0', 'balmPr', '21.0.40', day: 1);
  final balmBeta = v('balmB1', 'balmPr', '21.1.0-beta', type: 'beta', day: 20);
  final way = v(
    'wayV1',
    'waystone',
    '21.1.25',
    deps: [
      dep('balmPr'),
      dep('fabricApi'),
      dep('jeiPr', type: 'optional'),
    ],
  );
  // Iris 1.9.0 chiede una Sodium precisa che esiste solo per 1.21.4
  final sodium = v('sodiumV1', 'sodiumPr', '0.6.13');
  final sodium7 = v('sodiumV7', 'sodiumPr', '0.7.0', game: ['1.21.4'], day: 15);
  final iris = v('irisV1', 'irisPr', '1.8.8', deps: [dep('sodiumPr')]);
  final iris9 = v(
    'irisV9',
    'irisPr',
    '1.9.0',
    day: 16,
    deps: [dep('sodiumPr', version: 'sodiumV7')],
  );
  final lith = v('lithV1', 'lithiumPr', '0.15.0');
  final lith2 = v('lithV2', 'lithiumPr', '0.15.1', day: 5);
  final betaOnly = v('newB1', 'newPr', '1.0-beta', type: 'beta');
  final evil = v('evilV1', 'evilPr', '1.0', deps: [dep('lithiumPr', type: 'incompatible')]);

  MemoryCatalog catalog({Set<String> without = const {}}) => MemoryCatalog(
    projects: [
      proj('fabricApi'),
      proj('balmPr'),
      proj('waystone'),
      proj('sodiumPr', server: 'unsupported'),
      proj('irisPr', client: 'optional', server: 'unsupported'),
      proj('lithiumPr'),
      proj('newPr'),
      proj('evilPr'),
    ],
    versions: [
      for (final x in [
        fapi,
        fapi2,
        balm,
        balmOld,
        balmBeta,
        way,
        sodium,
        sodium7,
        iris,
        iris9,
        lith,
        lith2,
        betaOnly,
        evil,
      ])
        if (!without.contains(x.id)) x,
    ],
  );

  Pack base() => fabricPack([
    installed(fapi, project: proj('fabricApi')),
    installed(sodium, project: proj('sodiumPr', server: 'unsupported')),
    installed(
      iris,
      project: proj('irisPr', client: 'optional', server: 'unsupported'),
    ),
    installed(lith),
  ]);

  group('aggiungere', () {
    test('con la dipendenza obbligatoria mancante; quella presente basta', () {
      final plan = planAdd(base(), catalog(), 'waystone');
      expect(plan.ok, isTrue);
      expect(plan.mod!.versionNumber, '21.1.25');
      expect(plan.mod!.side, PackSide.both);
      expect(
        [for (final d in plan.dependencies) (d.projectId, d.versionNumber, d.auto)],
        [('balmPr', '21.0.46', true)],
      );
      expect([for (final s in plan.satisfied) s.projectId], ['fabricApi']);
      expect(plan.suggested, ['jeiPr']);
      expect(plan.mod!.requires, ['balmPr', 'fabricApi']);
      final p = plan.apply(base());
      expect(p.byProject('balmPr'), isNotNull);
      expect(p.mods.length, 6);
    });

    test('deterministico: catalogo in ordine diverso, stesso piano', () {
      final c2 = MemoryCatalog(
        projects: [proj('waystone'), proj('balmPr'), proj('fabricApi')],
        versions: [balmBeta, way, balmOld, fapi2, balm, fapi],
      );
      final a = planAdd(base(), catalog(), 'waystone').apply(base()).encode();
      final b = planAdd(base(), c2, 'waystone').apply(base()).encode();
      expect(b, a);
    });

    test('la release più recente, non la beta; solo beta → bloccata salvo permesso', () {
      final p = fabricPack([installed(fapi)]);
      expect(planAdd(p, catalog(), 'balmPr').mod!.versionNumber, '21.0.46');
      // anche con le beta permesse si preferisce la release
      expect(
        planAdd(p, catalog(), 'balmPr', maxType: MrVersionType.beta).mod!.versionNumber,
        '21.0.46',
      );
      expect(
        planAdd(p, catalog(), 'newPr', maxType: MrVersionType.beta).mod!.versionNumber,
        '1.0-beta',
      );
      final b = planAdd(p, catalog(), 'newPr');
      expect(b.ok, isFalse);
      expect(b.blockers.single.reason, BlockReason.onlyPrerelease);
      expect(b.blockers.single.versionNumber, '1.0-beta');
    });

    test('già installata, nessuna versione, dati non caricati, versione scelta', () {
      expect(
        planAdd(base(), catalog(), 'lithiumPr').blockers.single.reason,
        BlockReason.alreadyInstalled,
      );
      final forge = Pack(mcVersion: '1.21.1', loader: Loader.forge, loaderVersion: '52.0.40');
      expect(
        planAdd(forge, catalog(), 'balmPr').blockers.single.reason,
        BlockReason.noCompatibleVersion,
      );
      expect(planAdd(base(), catalog(), 'unknownPr').blockers.single.reason, BlockReason.notLoaded);
      expect(
        planAdd(
          fabricPack([installed(fapi)]),
          catalog(),
          'balmPr',
          versionId: 'balmV0',
        ).mod!.versionNumber,
        '21.0.40',
      );
      expect(
        planAdd(base(), catalog(), 'sodiumPr', versionId: 'sodiumV7').blockers.single.reason,
        anyOf(BlockReason.alreadyInstalled, BlockReason.noCompatibleVersion),
      );
    });

    test('dipendenza precisa che non gira qui: bloccata con le versioni', () {
      final p = fabricPack([installed(fapi)]);
      final plan = planAdd(p, catalog(), 'irisPr', versionId: 'irisV9');
      expect(plan.ok, isFalse);
      final b = plan.blockers.single;
      expect(b.reason, BlockReason.dependencyIncompatible);
      expect(b.otherProjectId, 'sodiumPr');
      expect(b.gameVersions, ['1.21.4']);
    });

    test('dipendenza che non esiste per il loader', () {
      final c = catalog()..addVersion(v('needV1', 'needPr', '1', deps: [dep('ghostPr')]));
      c.markLoaded('ghostPr');
      final plan = planAdd(fabricPack(const []), c, 'needPr');
      expect(plan.blockers.single.reason, BlockReason.dependencyUnavailable);
    });

    test('incompatibile con una mod installata', () {
      final plan = planAdd(base(), catalog(), 'evilPr');
      expect(plan.blockers.single.reason, BlockReason.conflict);
      expect(plan.blockers.single.otherProjectId, 'lithiumPr');
      expect(() => plan.apply(base()), throwsStateError);
    });

    test('Quilt accetta le mod Fabric', () {
      final q = Pack(mcVersion: '1.21.1', loader: Loader.quilt, loaderVersion: '0.29.0');
      expect(planAdd(q, catalog(), 'fabricApi').ok, isTrue);
    });
  });

  group('aggiornare', () {
    test('disponibile, aggiornata, bloccata con il motivo, non tracciata', () {
      final p = base().withMods([manual('mods/tweaks.jar')]);
      final checks = {for (final c in checkUpdates(p, catalog())) c.mod.projectId ?? c.mod.path: c};
      expect(checks['fabricApi']!.status, UpdateStatus.available);
      expect(checks['fabricApi']!.updated!.versionNumber, '0.116.9');
      expect(checks['sodiumPr']!.status, UpdateStatus.upToDate);
      expect(checks['lithiumPr']!.status, UpdateStatus.available);
      final ir = checks['irisPr']!;
      expect(ir.status, UpdateStatus.blocked);
      expect(ir.latest!.versionNumber, '1.9.0');
      expect(ir.blockers.single.reason, BlockReason.dependencyIncompatible);
      expect(ir.blockers.single.gameVersions, ['1.21.4']);
      expect(checks['mods/tweaks.jar']!.status, UpdateStatus.notTracked);
    });

    test('il lato e la facoltativa scelti restano; la bloccata dall\'admin no in «tutte»', () {
      final p = fabricPack([
        installed(fapi).copyWith(side: PackSide.server, optional: false),
        installed(lith, pinned: true),
      ]);
      final checks = checkUpdates(p, catalog());
      expect(checks.firstWhere((c) => c.mod.projectId == 'lithiumPr').status, UpdateStatus.pinned);
      final all = applyUpdates(p, checks);
      expect(all.byProject('fabricApi')!.versionId, 'fapiV2');
      expect(all.byProject('fabricApi')!.side, PackSide.server);
      expect(all.byProject('lithiumPr')!.versionId, 'lithV1');
      final forced = applyUpdates(p, checks, includePinned: true);
      expect(forced.byProject('lithiumPr')!.versionId, 'lithV2');
      expect(forced.byProject('lithiumPr')!.pinned, isTrue);
    });

    test('la dipendenza precisa più nuova si porta avanti; una nuova si aggiunge', () {
      final fapi3 = v('fapiV3', 'fabricApi', '0.117.0', day: 12);
      final pl1 = v('plV1', 'plPr', '1.0', deps: [dep('fabricApi')]);
      final pl2 = v(
        'plV2',
        'plPr',
        '2.0',
        day: 13,
        deps: [
          dep('fabricApi', version: 'fapiV3'),
          dep('balmPr'),
        ],
      );
      final c = catalog()
        ..addVersion(fapi3, listed: false)
        ..addVersion(pl1)
        ..addVersion(pl2);
      final p = fabricPack([installed(fapi), installed(pl1)]);
      final check = checkUpdate(p, c, p.byProject('plPr')!);
      expect(check.status, UpdateStatus.available);
      expect(check.alsoUpdate.single.versionId, 'fapiV3');
      expect(check.alsoAdd.single.projectId, 'balmPr');
      final out = applyUpdates(p, [check]);
      expect(out.byProject('fabricApi')!.versionId, 'fapiV3');
      expect(out.byProject('plPr')!.versionId, 'plV2');
      expect(out.byProject('balmPr')!.auto, isTrue);
    });

    test('versioni non caricate: stato sconosciuto', () {
      final p = fabricPack([installed(v('zzV1', 'zzPr', '1'))]);
      expect(checkUpdates(p, MemoryCatalog()).single.status, UpdateStatus.unknown);
    });
  });

  group('togliere', () {
    test('con le dipendenti, a catena, e le dipendenze orfane', () {
      final p = planAdd(base(), catalog(), 'waystone').apply(base());
      final rm = planRemove(p, p.byProject('balmPr')!.key);
      expect([for (final m in rm.dependents) m.projectId], ['waystone']);
      expect(rm.orphans, isEmpty); // fabricApi non è auto
      final out = rm.apply(p);
      expect(out.byProject('balmPr'), isNull);
      expect(out.byProject('waystone'), isNull);

      final rm2 = planRemove(p, p.byProject('waystone')!.key);
      expect(rm2.dependents, isEmpty);
      expect([for (final m in rm2.orphans) m.projectId], ['balmPr']);
      expect(rm2.apply(p, withOrphans: false).byProject('balmPr'), isNotNull);
      expect(() => planRemove(p, 'mr:nothing'), throwsArgumentError);
    });

    test('a mano: nessuna dipendente', () {
      final p = base().withMods([manual('mods/tweaks.jar')]);
      final rm = planRemove(p, p.byPath('mods/tweaks.jar')!.key);
      expect(rm.all.single.path, 'mods/tweaks.jar');
    });
  });

  group('cambiare versione o loader', () {
    test('rapporto per mod: pronte, bloccate, a mano; dipendenza bloccata blocca', () {
      final c = catalog()
        ..addVersion(v('fapi4', 'fabricApi', '0.120.0', game: ['1.21.4'], day: 20))
        ..addVersion(v('lith4', 'lithiumPr', '0.16.0', game: ['1.21.4'], day: 20))
        ..addVersion(
          v('iris4', 'irisPr', '1.9.0', game: ['1.21.4'], day: 20, deps: [dep('sodiumPr')]),
        )
        ..addVersion(v('sodB4', 'sodiumPr', '0.7.0-beta', game: ['1.21.4'], type: 'beta', day: 3));
      c.addVersion(sodium7);
      final p = base().withMods([manual('mods/tweaks.jar')]);
      final r = planRetarget(
        p,
        c,
        mcVersion: '1.21.4',
        loader: Loader.fabric,
        loaderVersion: '0.17.3',
      );
      final by = {for (final e in r.entries) e.mod.projectId ?? e.mod.path: e};
      expect(by['fabricApi']!.status, CompatStatus.ready);
      expect(by['fabricApi']!.next!.versionNumber, '0.120.0');
      expect(by['sodiumPr']!.next!.versionNumber, '0.7.0');
      expect(by['irisPr']!.status, CompatStatus.ready);
      expect(by['mods/tweaks.jar']!.status, CompatStatus.manual);
      final out = r.apply();
      expect(out.mcVersion, '1.21.4');
      expect(out.loaderVersion, '0.17.3');
      expect(out.byPath('mods/tweaks.jar'), isNotNull);
      expect(r.apply(keepManual: false).byPath('mods/tweaks.jar'), isNull);

      // senza Sodium per 1.21.4 Iris resta bloccata anche lei
      final c2 = catalog(without: {'sodiumV7'})
        ..addVersion(
          v('iris4', 'irisPr', '1.9.0', game: ['1.21.4'], day: 20, deps: [dep('sodiumPr')]),
        )
        ..addVersion(v('sodB4', 'sodiumPr', '0.7.0-beta', game: ['1.21.4'], type: 'beta', day: 3));
      final r2 = planRetarget(
        p,
        c2,
        mcVersion: '1.21.4',
        loader: Loader.fabric,
        loaderVersion: '0.17.3',
      );
      final by2 = {for (final e in r2.entries) e.mod.projectId ?? e.mod.path: e};
      expect(by2['sodiumPr']!.status, CompatStatus.blocked);
      expect(by2['sodiumPr']!.blockers.single.reason, BlockReason.onlyPrerelease);
      expect(by2['irisPr']!.blockers.single.reason, BlockReason.dependencyBlocked);
      expect(by2['fabricApi']!.blockers.single.reason, BlockReason.noCompatibleVersion);
      expect(r2.apply().mods.map((m) => m.path), ['mods/tweaks.jar']);
    });

    test('la versione attuale che gira già sul nuovo target resta', () {
      final wide = v('wideV1', 'widePr', '1.0', game: ['1.21.1', '1.21.4']);
      final c = MemoryCatalog(
        versions: [
          wide,
          v('wideV2', 'widePr', '2.0', game: ['1.21.4'], day: 9),
        ],
      );
      final p = fabricPack([installed(wide)]);
      final r = planRetarget(
        p,
        c,
        mcVersion: '1.21.4',
        loader: Loader.fabric,
        loaderVersion: '0.17.3',
      );
      expect(r.entries.single.unchanged, isTrue);
    });

    test('nuove dipendenze richieste dalle versioni scelte', () {
      final a1 = v('a1', 'aPr', '1');
      final c = MemoryCatalog(
        versions: [
          a1,
          v('a2', 'aPr', '2', loaders: ['neoforge'], deps: [dep('libPr')]),
          v('lib1', 'libPr', '1', loaders: ['neoforge']),
        ],
      );
      final r = planRetarget(
        fabricPack([installed(a1)]),
        c,
        mcVersion: '1.21.1',
        loader: Loader.neoforge,
        loaderVersion: '21.1.77',
      );
      expect(r.alsoAdd.single.projectId, 'libPr');
      expect(r.apply().loader, Loader.neoforge);
      expect(r.apply().mods.length, 2);
    });
  });

  test('CatalogLoader: carica progetti, versioni per il target e dipendenze', () async {
    final t = FakeTransport({
      'GET api.modrinth.com/v2/projects': (req) =>
          req.url.queryParameters['ids']!.contains('waystone')
          ? json([projectJson('waystone')])
          : json([projectJson('balmPr')]),
      'GET api.modrinth.com/v2/versions': (_) => json(<Object?>[]),
      'GET api.modrinth.com/v2/project/waystone/version': (_) => json([
        versionJson(id: 'wayV1', project: 'waystone', number: '21.1.25', deps: [dep('balmPr')]),
      ]),
      'GET api.modrinth.com/v2/project/balmPr/version': (_) =>
          json([versionJson(id: 'balmV1', project: 'balmPr', number: '21.0.46')]),
    });
    final c = ModrinthClient(transport: t, userAgent: 'minesync/test', sleep: (_) async {});
    final cat = await CatalogLoader(c).forAdd(fabricPack(const []), 'waystone');
    final plan = planAdd(fabricPack(const []), cat, 'waystone');
    expect(plan.ok, isTrue);
    expect(plan.dependencies.single.projectId, 'balmPr');
    final vreq = t.requests.where((r) => r.url.path.endsWith('/version')).first;
    expect(vreq.url.queryParameters['game_versions'], '["1.21.1"]');
    expect(vreq.url.queryParameters['loaders'], '["fabric"]');
  });
}
