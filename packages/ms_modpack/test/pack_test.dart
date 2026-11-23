// Il file minesync-pack.json: codifica canonica, validazione, differenze e
// confronto con i jar presenti.
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart' show Exclusions, minecraftExclusions;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  final create = v('createV1', 'createPr', '6.0.6');
  final sodium = v('sodiumV1', 'sodiumPr', '0.6.13');

  group('codifica', () {
    test('andata e ritorno identici, byte canonici e ordinati', () {
      final p = fabricPack([
        installed(sodium, project: proj('sodiumPr', server: 'unsupported')),
        installed(create),
        manual('mods/survival-tweaks.jar'),
      ]).copyWith(shared: ['config/**']);
      final text = p.encode();
      expect(text.endsWith('}\n'), isTrue);
      final back = Pack.decode(text);
      expect(back.encode(), text);
      expect(back, p);
      // ordine per percorso, a prescindere dall'ordine di costruzione
      expect(
        [for (final m in back.mods) m.path],
        ['mods/createPr-6.0.6.jar', 'mods/sodiumPr-0.6.13.jar', 'mods/survival-tweaks.jar'],
      );
      final again = fabricPack(back.mods.reversed).copyWith(shared: ['config/**']);
      expect(again.encode(), text);
    });

    test('campi di default omessi; formato sconosciuto rifiutato', () {
      final j = fabricPack([manual('mods/a.jar')]).toJson();
      final mod = (j['mods']! as List<Object?>).first! as Map<String, Object?>;
      expect(mod.containsKey('pinned'), isFalse);
      expect(mod.containsKey('downloads'), isFalse);
      expect(() => Pack.fromJson({...j, 'format': 2}), throwsFormatException);
      expect(() => Pack.decode('{nope'), throwsFormatException);
    });

    test('il lato client vive sotto client-overrides/, spenta con .disabled', () {
      final m = manual('mods/minimap.jar', side: PackSide.client);
      expect(m.location, 'client-overrides/mods/minimap.jar');
      expect(m.copyWith(disabled: true).diskLocation, 'client-overrides/mods/minimap.jar.disabled');
      expect(manual('mods/x.jar').diskLocation, 'mods/x.jar');
    });
  });

  group('validazione', () {
    test('percorsi: .., assoluti, cartelle speciali, suffisso .disabled', () {
      for (final bad in [
        '../escape.jar',
        '/abs.jar',
        'mods/../x.jar',
        'mods\\x.jar',
        'client-overrides/mods/x.jar',
        'overrides/mods/x.jar',
        '.minesync/x.jar',
        'mods/x.jar.disabled',
        'minesync-pack.json',
        'mods/con.jar',
      ]) {
        expect(() => manual(bad), throwsFormatException, reason: bad);
      }
    });

    test('hash, URL, id e regole del pack', () {
      final ok = manual('mods/a.jar');
      expect(() => ok.copyWith(sha1: 'abc'), throwsFormatException);
      expect(() => ok.copyWith(sha512: 'abc'), throwsFormatException);
      expect(() => ok.copyWith(downloads: ['http://cdn.example/a.jar']), throwsFormatException);
      expect(() => ok.copyWith(source: PackSource.modrinth), throwsFormatException);
      expect(() => ok.copyWith(projectId: 'bad id!'), throwsFormatException);
      expect(
        () => Pack(mcVersion: '1.21.1', loader: Loader.paper, loaderVersion: '1'),
        throwsFormatException,
      );
      expect(
        () => Pack(mcVersion: '1.21.1', loader: Loader.vanilla, loaderVersion: '1'),
        throwsFormatException,
      );
      expect(() => Pack(mcVersion: '1.21.1', loader: Loader.fabric), throwsFormatException);
      expect(() => Pack(mcVersion: ' 1.21.1', loader: Loader.vanilla), throwsFormatException);
      expect(() => fabricPack([ok, manual('mods/A.jar')]), throwsFormatException);
      expect(
        () => fabricPack([installed(create), installed(v('createV2', 'createPr', '6.0.8'))]),
        throwsFormatException,
      );
    });
  });

  group('esclusioni', () {
    test('il file del pack e client-overrides/ si sincronizzano', () {
      final ex = Exclusions(minecraftExclusions);
      expect(ex.excludes(packFileName), isFalse);
      expect(ex.excludes('client-overrides/mods/minimap.jar'), isFalse);
      expect(ex.excludes('client-overrides/config/x.json'), isFalse);
      expect(ex.excludes('mods/x.jar.disabled'), isFalse);
      // la cartella temporanea dei download invece no
      expect(ex.excludes('.minesync-modpack.tmp/0-x.jar'), isTrue);
      expect(ex.excludes('mods/x.jar.minesyncpart'), isTrue);
    });
  });

  group('differenze', () {
    test('aggiunte, tolte, aggiornate, spente, altri campi, versione', () {
      final a = fabricPack([installed(create), installed(sodium), manual('mods/m.jar')]);
      final b = fabricPack([
        installed(v('createV2', 'createPr', '6.0.8')),
        installed(sodium).copyWith(disabled: true),
        manual('mods/m.jar', side: PackSide.both),
        manual('mods/new.jar'),
      ]).copyWith(mcVersion: '1.21.4');
      final d = PackDiff(a, b);
      expect(d.mcVersion, ('1.21.1', '1.21.4'));
      expect(d.loader, isNull);
      expect(d.added.single.path, 'mods/new.jar');
      expect(d.removed, isEmpty);
      expect(d.updated.single.$2.versionNumber, '6.0.8');
      expect(d.toggled.single.$1.projectId, 'sodiumPr');
      expect(d.changed.single.$2.side, PackSide.both);
      expect(d.touchesFiles, isTrue);
      expect(PackDiff(a, a).isEmpty, isTrue);
      expect(PackDiff(a, fabricPack([installed(create)])).removed.length, 2);
    });
  });

  group('confronto con i file', () {
    test('mancanti, sostituiti a mano, sconosciuti', () {
      final c = installed(create);
      final s = installed(sodium);
      final pack = fabricPack([c, s]);
      final files = [
        LocalFile(path: c.location, size: c.size, sha1: c.sha1),
        LocalFile(path: s.location, size: 3, sha1: 'f' * 40),
        const LocalFile(path: 'mods/unknown.jar', size: 4, sha1: 'aaaa'),
        const LocalFile(path: 'mods/sub/deep.jar', size: 4, sha1: 'bbbb'),
        const LocalFile(path: 'config/x.toml', size: 4, sha1: 'cccc'),
        const LocalFile(path: 'client-overrides/mods/cl.jar.disabled', size: 4, sha1: 'dddd'),
      ];
      final r = checkPack(pack, files);
      expect(r.missing, isEmpty);
      expect(r.mismatched.single.$1.projectId, 'sodiumPr');
      expect(
        [for (final f in r.untracked) f.path],
        ['client-overrides/mods/cl.jar.disabled', 'mods/unknown.jar'],
      );
      expect(checkPack(pack, const []).missing.length, 2);
    });

    test('un jar sconosciuto diventa manuale, di default solo server', () {
      final b = fakeJar('x');
      final f = LocalFile(path: 'mods/x.jar', size: b.length, sha1: sha1Of(b), sha512: sha512Of(b));
      final m = manualEntry(f);
      expect(m.side, PackSide.server);
      expect(m.source, PackSource.manual);
      expect(m.location, 'mods/x.jar');
      final cl = manualEntry(
        LocalFile(
          path: 'client-overrides/mods/y.jar.disabled',
          size: 1,
          sha1: sha1Of(b),
          sha512: sha512Of(b),
        ),
      );
      expect(cl.side, PackSide.client);
      expect(cl.disabled, isTrue);
      expect(cl.path, 'mods/y.jar');
      expect(manualEntry(f, side: PackSide.both).side, PackSide.both);
      expect(
        () => manualEntry(const LocalFile(path: 'mods/z.jar', size: 1, sha1: 'a')),
        throwsArgumentError,
      );
    });

    test('CurseForge a mano: pagina, niente URL, distribuzione vietata', () {
      final b = fakeJar('towers');
      final m = curseForgeEntry(
        LocalFile(path: 'mods/towers.jar', size: b.length, sha1: sha1Of(b), sha512: sha512Of(b)),
        pageUrl: curseForgeProjectUrl('ancient-towers'),
        side: PackSide.both,
      );
      expect(m.source, PackSource.curseforge);
      expect(m.downloads, isEmpty);
      expect(m.curseforge!.allowDistribution, isFalse);
      expect(PackMod.fromJson(m.toJson()), m);
    });
  });

  test('link a Temurin', () {
    expect(temurinUrl(21), 'https://adoptium.net/temurin/releases/?version=21');
    expect(temurinUrl(0), 'https://adoptium.net/');
  });
}
