// Formato .mrpack: import con validazione dei percorsi, export del
// pacchetto per i giocatori e andata e ritorno.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

import 'support.dart';

Map<String, Object?> fileEntry(
  String path, {
  String? url,
  String? client,
  String? server,
  List<int>? bytes,
}) {
  final b = bytes ?? fakeJar(path);
  return {
    'path': path,
    'hashes': {'sha1': sha1Of(b), 'sha512': sha512Of(b)},
    if (client != null) 'env': {'client': client, 'server': server ?? 'required'},
    'downloads': [
      url ??
          'https://cdn.modrinth.com/data/${mrId(path.split('/').last)}/versions/vers0001/${path.split('/').last}',
    ],
    'fileSize': b.length,
  };
}

Uint8List mrpack(Map<String, Object?> index, [Map<String, List<int>> extra = const {}]) {
  final a = Archive()
    ..add(ArchiveFile.bytes('modrinth.index.json', utf8.encode(jsonEncode(index))));
  for (final e in extra.entries) {
    a.add(ArchiveFile.bytes(e.key, e.value));
  }
  return ZipEncoder().encodeBytes(a);
}

Map<String, Object?> index({
  List<Map<String, Object?>> files = const [],
  Map<String, String>? deps,
}) => {
  'formatVersion': 1,
  'game': 'minecraft',
  'versionId': '1.0.0',
  'name': 'Avventura',
  'summary': 'A test pack',
  'files': files,
  'dependencies': deps ?? {'minecraft': '1.21.1', 'fabric-loader': '0.16.14'},
};

void main() {
  group('import', () {
    test('mod, lati, facoltative, sorgenti, override e jar negli override', () {
      final tweaks = utf8.encode('tweaks');
      final imp = readMrpack(
        mrpack(
          index(
            files: [
              fileEntry(
                'mods/create.jar',
                url: 'https://cdn.modrinth.com/data/createPr/versions/createV1/create.jar',
              ),
              fileEntry('mods/sodium.jar', client: 'required', server: 'unsupported'),
              fileEntry('mods/iris.jar', client: 'optional', server: 'unsupported'),
              fileEntry('mods/chunky.jar', client: 'unsupported', server: 'required'),
              fileEntry('mods/towers.jar', url: 'https://edge.forgecdn.net/files/1/2/towers.jar'),
              fileEntry(
                'mods/gh.jar',
                url: 'https://github.com/someone/gh/releases/download/v1/gh.jar',
              ),
              fileEntry('resourcepacks/pack.zip', client: 'optional', server: 'optional'),
            ],
          ),
          {
            'overrides/config/create.toml': utf8.encode('a=1'),
            'overrides/options.txt': utf8.encode('x'),
            'overrides/mods/tweaks.jar': tweaks,
            'server-overrides/config/create.toml': utf8.encode('a=2'),
            'server-overrides/server.properties': utf8.encode('motd=hi'),
            'client-overrides/config/iris.properties': utf8.encode('shaders=on'),
            'stray.txt': utf8.encode('?'),
          },
        ),
      );
      final p = imp.pack;
      expect(p.mcVersion, '1.21.1');
      expect(p.loader, Loader.fabric);
      expect(p.loaderVersion, '0.16.14');
      expect(p.name, 'Avventura');
      final create = p.byPath('mods/create.jar')!;
      expect(
        (create.source, create.projectId, create.versionId),
        (PackSource.modrinth, 'createPr', 'createV1'),
      );
      expect(create.side, PackSide.both);
      expect(p.byPath('mods/sodium.jar')!.side, PackSide.client);
      expect(p.byPath('mods/sodium.jar')!.location, 'client-overrides/mods/sodium.jar');
      expect(p.byPath('mods/iris.jar')!.optional, isTrue);
      expect(p.byPath('mods/chunky.jar')!.side, PackSide.server);
      expect(p.byPath('mods/towers.jar')!.source, PackSource.curseforge);
      expect(p.byPath('mods/towers.jar')!.curseforge!.allowDistribution, isTrue);
      expect(p.byPath('mods/gh.jar')!.source, PackSource.manual);
      expect(p.byPath('resourcepacks/pack.zip')!.optional, isTrue);
      final tw = p.byPath('mods/tweaks.jar')!;
      expect((tw.source, tw.side, tw.sha1), (PackSource.manual, PackSide.both, sha1Of(tweaks)));
      expect(p.shared, ['config/**', 'options.txt']);
      final files = {for (final f in imp.files) f.path: utf8.decode(f.bytes)};
      expect(files['config/create.toml'], 'a=2'); // server-overrides vince
      expect(files['server.properties'], 'motd=hi');
      expect(files['client-overrides/config/iris.properties'], 'shaders=on');
      expect(files['mods/tweaks.jar'], 'tweaks');
      expect(imp.warnings, ['ignored: stray.txt']);
    });

    test('percorsi pericolosi rifiutati (indice e override)', () {
      for (final bad in [
        '../evil.jar',
        '/etc/x.jar',
        'mods/../../x.jar',
        '.minesync/state.json',
        'mods/a:b.jar',
        'client-overrides/mods/x.jar',
      ]) {
        expect(
          () => readMrpack(mrpack(index(files: [fileEntry(bad)]))),
          throwsA(isA<MrpackError>().having((e) => e.reason, 'reason', 'badPath')),
          reason: bad,
        );
      }
      for (final bad in [
        'overrides/../x',
        'overrides/.minesync/lock',
        'overrides/minesync-pack.json',
        'overrides/client-overrides/x',
        'server-overrides/a/./b',
      ]) {
        expect(
          () => readMrpack(
            mrpack(index(), {
              bad: [1],
            }),
          ),
          throwsA(isA<MrpackError>()),
          reason: bad,
        );
      }
    });

    test('indice mancante o rotto, gioco o formato diversi, due loader, ZIP rotto', () {
      Matcher reason(String r) => throwsA(isA<MrpackError>().having((e) => e.reason, 'reason', r));
      final noIdx = ZipEncoder().encodeBytes(Archive()..add(ArchiveFile.bytes('overrides/a', [1])));
      expect(() => readMrpack(noIdx), reason('noIndex'));
      expect(
        () => readMrpack(mrpack({...index(), 'formatVersion': 2})),
        reason('unsupportedFormat'),
      );
      expect(() => readMrpack(mrpack({...index(), 'game': 'other'})), reason('unsupportedGame'));
      expect(
        () =>
            readMrpack(mrpack(index(deps: {'minecraft': '1.21.1', 'forge': '1', 'neoforge': '2'}))),
        reason('badLoader'),
      );
      expect(() => readMrpack(mrpack(index(deps: {'fabric-loader': '1'}))), reason('badIndex'));
      expect(
        () => readMrpack(
          mrpack(
            index(
              files: [
                {
                  ...fileEntry('mods/a.jar'),
                  'downloads': ['http://x/a.jar'],
                },
              ],
            ),
          ),
        ),
        reason('badIndex'),
      );
      expect(
        () => readMrpack(mrpack(index(files: [fileEntry('mods/a.jar'), fileEntry('mods/A.jar')]))),
        reason('badIndex'),
      );
      expect(() => readMrpack(Uint8List.fromList([1, 2, 3])), reason('badZip'));
      final big = mrpack(index(), {'overrides/big.bin': List.filled(2000, 7)});
      expect(() => readMrpack(big, maxBytes: 1000), reason('tooLarge'));
    });

    test('vanilla e NeoForge', () {
      final van = readMrpack(mrpack(index(deps: {'minecraft': '1.21.4'}))).pack;
      expect((van.loader, van.loaderVersion), (Loader.vanilla, null));
      final neo = readMrpack(
        mrpack(index(deps: {'minecraft': '1.21.1', 'neoforge': '21.1.77'})),
      ).pack;
      expect((neo.loader, neo.loaderVersion), (Loader.neoforge, '21.1.77'));
    });

    test('id Modrinth dagli URL del CDN', () {
      expect(
        modrinthIdsFromUrl('https://cdn.modrinth.com/data/AANobbMI/versions/u6dRKJwZ/sodium.jar'),
        ('AANobbMI', 'u6dRKJwZ'),
      );
      expect(modrinthIdsFromUrl('https://cdn.modrinth.com/other/x'), isNull);
      expect(modrinthIdsFromUrl('https://example.com/data/a/versions/b/c.jar'), isNull);
    });
  });

  group('export del pacchetto per i giocatori', () {
    PackMod mr(
      String path, {
      PackSide side = PackSide.both,
      bool optional = false,
      String id = 'aaaa0001',
    }) {
      final b = fakeJar(path);
      return PackMod(
        path: path,
        sha1: sha1Of(b),
        sha512: sha512Of(b),
        size: b.length,
        side: side,
        optional: optional,
        source: PackSource.modrinth,
        projectId: id,
        versionId: 'vvvv0001',
        downloads: ['https://cdn.modrinth.com/data/$id/versions/vvvv0001/${path.split('/').last}'],
      );
    }

    late Pack pack;
    late List<String> serverFiles;
    setUp(() {
      pack = fabricPack([
        mr('mods/create.jar', id: 'createPr'),
        mr('mods/sodium.jar', side: PackSide.client, id: 'sodiumPr'),
        mr('mods/iris.jar', side: PackSide.client, optional: true, id: 'irisPr'),
        mr('mods/chunky.jar', side: PackSide.server, id: 'chunkyPr'),
        mr('mods/minimap.jar', side: PackSide.client, id: 'mapPr').copyWith(disabled: true),
        manual('mods/tweaks.jar', side: PackSide.both),
        manual('mods/lost.jar', side: PackSide.client),
        curseForgeEntry(
          LocalFile(path: 'mods/towers.jar', size: 1, sha1: sha1Of([1]), sha512: sha512Of([1])),
          pageUrl: 'https://www.curseforge.com/minecraft/mc-mods/towers',
          side: PackSide.both,
        ),
      ]).copyWith(shared: ['config/**', 'options.txt']);
      serverFiles = [
        'minesync-pack.json',
        'server.properties',
        'options.txt',
        'config/create.toml',
        'mods/create.jar',
        'mods/chunky.jar',
        'mods/tweaks.jar',
        'mods/towers.jar',
        'mods/untracked.jar',
        'client-overrides/mods/sodium.jar',
        'client-overrides/mods/iris.jar',
        'client-overrides/mods/minimap.jar.disabled',
        'client-overrides/config/iris.properties',
        'world/level.dat',
      ];
    });

    test('per URL, override, mancanti; facoltative tenute tutte (hub)', () {
      final plan = planClientPack(pack, serverFiles, versionId: '129', name: 'Survival');
      final idx = {for (final f in plan.index.files) f.path: f};
      expect(idx.keys, unorderedEquals(['mods/create.jar', 'mods/sodium.jar', 'mods/iris.jar']));
      expect(idx['mods/iris.jar']!.env!.client, MrEnv.optional);
      expect(idx['mods/sodium.jar']!.env!.server, MrEnv.unsupported);
      expect(idx['mods/create.jar']!.env!.server, MrEnv.required);
      expect(
        [for (final o in plan.overrides) o.zipPath],
        [
          'client-overrides/config/iris.properties',
          'overrides/config/create.toml',
          'overrides/mods/tweaks.jar',
          'overrides/options.txt',
        ],
      );
      expect([
        for (final m in plan.missing) (m.file, m.source),
      ], unorderedEquals([('lost.jar', 'manual'), ('towers.jar', 'curseforge')]));
      expect(
        plan.missing.firstWhere((m) => m.file == 'towers.jar').pageUrl,
        contains('curseforge.com'),
      );
      expect(plan.index.dependencies, {'minecraft': '1.21.1', 'fabric-loader': '0.16.14'});
      expect(
        [for (final e in plan.modsZip) e.zipPath],
        ['mods/create.jar', 'mods/iris.jar', 'mods/sodium.jar', 'mods/tweaks.jar'],
      );
      final s = plan.summary(n: 129, fileName: 'Survival-129.mrpack');
      expect(
        (s.mods, s.required, s.optional, s.serverOnly, s.manual, s.disabled),
        (8, 5, 1, 1, 2, 1),
      );
      expect(ClientPack.fromJson(jsonDecode(jsonEncode(s.toJson()))).toJson(), s.toJson());
    });

    test('sul PC: solo le facoltative scelte, come obbligatorie', () {
      final none = planClientPack(pack, serverFiles, versionId: '1', chosenOptional: {});
      expect(none.index.files.map((f) => f.path), isNot(contains('mods/iris.jar')));
      final iris = pack.byPath('mods/iris.jar')!.key;
      final some = planClientPack(pack, serverFiles, versionId: '1', chosenOptional: {iris});
      expect(
        some.index.files.firstWhere((f) => f.path == 'mods/iris.jar').env!.client,
        MrEnv.required,
      );
    });

    test('andata e ritorno: export e poi import', () {
      final bytes = <String, Uint8List>{
        for (final f in serverFiles)
          f: Uint8List.fromList(
            f.startsWith('mods/') || f.startsWith('client-overrides/mods/')
                ? fakeJar(f.split('/').last == 'tweaks.jar' ? 'mods/tweaks.jar' : f)
                : utf8.encode('content of $f'),
          ),
      };
      final plan = planClientPack(pack, serverFiles, versionId: '129', name: 'Survival');
      final zip = writeMrpack(plan, (s) => bytes[s]);
      final back = readMrpack(zip);
      expect(back.index.versionId, '129');
      expect(back.pack.mcVersion, pack.mcVersion);
      expect(back.pack.loaderVersion, pack.loaderVersion);
      for (final f in plan.index.files) {
        final m = back.pack.byPath(f.path)!;
        final orig = pack.byPath(f.path)!;
        expect(
          (m.sha1, m.sha512, m.side, m.optional, m.source, m.projectId),
          (orig.sha1, orig.sha512, orig.side, orig.optional, orig.source, orig.projectId),
        );
      }
      expect(back.pack.byPath('mods/tweaks.jar')!.sha1, pack.byPath('mods/tweaks.jar')!.sha1);
      expect(back.pack.shared, ['config/**', 'options.txt']);
      expect(() => writeMrpack(plan, (_) => null), throwsStateError);
    });

    test('host non ammessi: il jar va negli override se c\'è', () {
      final gh = manual(
        'mods/x.jar',
        side: PackSide.both,
      ).copyWith(downloads: ['https://example.org/x.jar']);
      final p = fabricPack([gh]);
      final plan = planClientPack(p, ['mods/x.jar'], versionId: '1');
      expect(plan.index.files, isEmpty);
      expect(plan.overrides.single.zipPath, 'overrides/mods/x.jar');
      final plan2 = planClientPack(p, const [], versionId: '1');
      expect(plan2.missing.single.file, 'x.jar');
    });
  });
}
