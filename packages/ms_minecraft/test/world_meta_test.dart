// Metadati del mondo: NBT e level.dat (B-META-01, B-META-04), jar delle mod
// (B-META-02, B-META-03), URL sicuri (B-META-05), giocatori,
// server.properties e riassunto del server dai percorsi.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// level.dat sintetico (non compresso) nel formato classico.
Uint8List levelDat({bool newSpawn = false, bool oldSeed = false}) {
  final w = NbtWriter()
    ..begin('')
    ..begin('Data')
    ..string('LevelName', 'Survival')
    ..int32('DataVersion', 3955)
    ..begin('Version')
    ..string('Name', '1.21.1')
    ..int32('Id', 3955)
    ..end()
    ..byte('Difficulty', 2)
    ..byte('hardcore', 1)
    ..int32('GameType', 0)
    ..int64('Time', 24000 * 37 + 500);
  if (oldSeed) {
    w.int64('RandomSeed', 42);
  } else {
    w
      ..begin('WorldGenSettings')
      ..int64('seed', -8613491928117260000)
      ..end();
  }
  if (newSpawn) {
    w
      ..begin('spawn')
      ..intArray('pos', [10, 70, -20])
      ..string('dimension', 'minecraft:overworld')
      ..end();
  } else {
    w
      ..int32('SpawnX', 1)
      ..int32('SpawnY', 64)
      ..int32('SpawnZ', -3);
  }
  w
    ..intList('Lista', [1, 2, 3])
    ..end()
    ..end();
  return w.takeBytes();
}

Uint8List gz(Uint8List b) => Uint8List.fromList(gzip.encode(b));

void main() {
  group('NBT', () {
    test('B-META-01 level.dat gzip: nome, versione, seed, difficoltà, giorno, spawn', () {
      final l = parseLevelDat(gz(levelDat()));
      expect(l.name, 'Survival');
      expect(l.version, '1.21.1');
      expect(l.dataVersion, 3955);
      expect(l.seed, '-8613491928117260000');
      expect(l.difficulty, Difficulty.normal);
      expect(l.hardcore, isTrue);
      expect(l.gameMode, GameMode.survival);
      expect(l.day, 37);
      expect(l.timeTicks, 24000 * 37 + 500);
      expect(l.spawn!.toJson(), {'x': 1, 'y': 64, 'z': -3});
    });

    test('B-META-01 seed da RandomSeed, spawn nel compound recente, zlib e non compresso', () {
      final raw = levelDat(newSpawn: true, oldSeed: true);
      for (final b in [raw, Uint8List.fromList(zlib.encode(raw))]) {
        final l = parseLevelDat(b);
        expect(l.seed, '42');
        expect(l.spawn!.toJson(), {'x': 10, 'y': 70, 'z': -20});
      }
    });

    test('B-META-01 campi assenti restano null; seed da world_gen_settings.dat', () {
      final w = NbtWriter()
        ..begin('')
        ..begin('Data')
        ..string('LevelName', 'x')
        ..end()
        ..end();
      final l = parseLevelDat(w.takeBytes());
      expect(l.toJson(), {'name': 'x'});
      final s = NbtWriter()
        ..begin('')
        ..begin('data')
        ..int64('seed', 7)
        ..end()
        ..end();
      expect(parseWorldGenSeed(gz(s.takeBytes())), '7');
      expect(parseWorldGenSeed(Uint8List.fromList([1, 2, 3])), isNull);
    });

    test('B-META-04 lista che dichiara più elementi dei byte rimasti: rifiutata', () {
      final b = Uint8List.fromList([10, 0, 0, 9, 0, 1, 0x6c, 10, 0x00, 0xff, 0xff, 0xff, 0]);
      expect(() => readNbt(b), throwsFormatException);
      final big = Uint8List.fromList([10, 0, 0, 9, 0, 1, 0x6c, 10, 0x7f, 0xff, 0xff, 0xff, 0]);
      expect(() => readNbt(big), throwsFormatException);
    });

    test('B-META-04 300 000 nodi da un byte: oltre il tetto; il level valido passa', () {
      const n = 300000;
      final w = NbtWriter()
        ..begin('')
        ..raw([9, 0, 1, 0x6c, 1])
        ..raw((ByteData(4)..setInt32(0, n)).buffer.asUint8List())
        ..raw(Uint8List(n))
        ..end();
      expect(() => readNbt(w.takeBytes()), throwsFormatException);
      // anche come compound di byte uno per uno
      final c = NbtWriter()..begin('');
      for (var i = 0; i < n; i++) {
        c.byte('', 0);
      }
      c.end();
      expect(() => readNbt(c.takeBytes()), throwsFormatException);
      expect(readNbt(levelDat())['Data'], isA<Map<String, Object?>>());
    });

    test('B-META-04 profondità, array negativi, tipi ignoti, bomba gzip', () {
      final deep = BytesBuilder()..add([10, 0, 0]);
      for (var i = 0; i < 600; i++) {
        deep.add([10, 0, 0]);
      }
      expect(() => readNbt(deep.takeBytes()), throwsFormatException);
      expect(
        () => readNbt(Uint8List.fromList([10, 0, 0, 11, 0, 1, 0x61, 0xff, 0xff, 0xff, 0xff, 0])),
        throwsFormatException,
      );
      expect(() => readNbt(Uint8List.fromList([10, 0, 0, 13, 0, 0, 0])), throwsFormatException);
      expect(() => readNbt(Uint8List.fromList([8, 0, 0])), throwsFormatException);
      // 32 MiB di zeri compressi in pochi KiB: fermati al tetto
      final bomb = gz(Uint8List(32 << 20));
      expect(() => readNbt(bomb), throwsFormatException);
    });

    test('B-META-04 fuzz con seed fisso: solo FormatException', () {
      final rng = Random(20261122);
      final seeds = [levelDat(), gz(levelDat()), levelDat(newSpawn: true)];
      var parsed = 0;
      for (var i = 0; i < 3000; i++) {
        final base = seeds[i % seeds.length];
        final b = Uint8List.fromList(base);
        final flips = 1 + rng.nextInt(8);
        for (var k = 0; k < flips; k++) {
          b[rng.nextInt(b.length)] = rng.nextInt(256);
        }
        final cut = rng.nextInt(4) == 0 ? rng.nextInt(b.length) : b.length;
        final input = Uint8List.sublistView(b, 0, cut);
        try {
          readNbt(input);
          parseLevelDat(input);
          parsed++;
        } on FormatException {
          // atteso
        }
      }
      // byte del tutto casuali
      for (var i = 0; i < 2000; i++) {
        final b = Uint8List.fromList(List.generate(rng.nextInt(64), (_) => rng.nextInt(256)));
        try {
          readNbt(b);
        } on FormatException {
          // atteso
        }
      }
      expect(parsed, greaterThan(0));
    });
  });

  group('jar delle mod', () {
    const forgeToml = '''
modLoader="javafml"
loaderVersion="[47,)"
license="MIT"
logoFile="logo.png"

[[mods]]
modId="examplemod"
version="1.2.3"
displayName="Example Mod" # commento
displayURL="https://example.com/mod"
authors="alice, bob"
description=\'\'\'
Prima riga.
Seconda riga.
\'\'\'

[[dependencies.examplemod]]
    modId="forge"
    versionRange="[47,)"
[[dependencies.examplemod]]
    modId="minecraft"
    versionRange="[1.20.1,1.21)"
''';

    test(
      'B-META-02 Forge mods.toml: id, nome, versione, autori, licenza, descrizione, icona',
      () async {
        final jar = await ZipArchive.open(
          BytesSource(zipBytes({'META-INF/mods.toml': forgeToml, 'logo.png': tinyPng()})),
        );
        final m = (await readModMeta(jar!))!;
        expect(m.id, 'examplemod');
        expect(m.name, 'Example Mod');
        expect(m.version, '1.2.3');
        expect(m.loader, Loader.forge);
        expect(m.mcVersion, '[1.20.1,1.21)');
        expect(m.authors, ['alice', 'bob']);
        expect(m.license, 'MIT');
        expect(m.description, 'Prima riga.\nSeconda riga.');
        expect(m.homepage, 'https://example.com/mod');
        expect(m.iconPath, 'logo.png');
        final icon = await readModIcon(jar, m.iconPath!);
        expect(icon, tinyPng());
      },
    );

    test('B-META-02 NeoForge neoforge.mods.toml e versione \${file.jarVersion} ignorata', () async {
      final toml = forgeToml.replaceAll('1.2.3', r'${file.jarVersion}');
      final jar = await ZipArchive.open(
        BytesSource(zipBytes({'META-INF/neoforge.mods.toml': toml}, deflate: false)),
      );
      final m = (await readModMeta(jar!))!;
      expect(m.loader, Loader.neoforge);
      expect(m.version, isNull);
    });

    test(
      'B-META-03 Fabric: a capo e tabulazioni grezzi nelle stringhe, come li accetta Fabric',
      () async {
        // diverse mod reali (es. Debugify) hanno la descrizione su più righe
        // senza escape: il JSON è tecnicamente non valido ma Fabric lo legge
        const json =
            '{\n  "schemaVersion": 1,\n  "id": "multi",\n  "version": "1.0",\n'
            '  "name": "Multi\triga",\n  "description": "Prima riga.\n\nSeconda \\"riga\\".",\n'
            '  "authors": ["alice"]\n}';
        final jar = await ZipArchive.open(BytesSource(zipBytes({'fabric.mod.json': json})));
        final m = (await readModMeta(jar!))!;
        expect(m.id, 'multi');
        expect(m.name, 'Multi\triga');
        expect(m.description, 'Prima riga.\n\nSeconda "riga".');
        expect(m.authors, ['alice']);
      },
    );

    test('B-META-03 Fabric: autori stringhe o oggetti, contact.homepage, icona', () async {
      final json = jsonEncode({
        'schemaVersion': 1,
        'id': 'fab',
        'version': '0.9.0',
        'name': 'Fab',
        'authors': [
          'alice',
          {'name': 'bob'},
        ],
        'contact': {'homepage': 'https://example.org'},
        'license': 'Apache-2.0',
        'icon': {'16': 'assets/s.png', '128': 'assets/b.png'},
        'depends': {'minecraft': '~1.21'},
      });
      final jar = await ZipArchive.open(
        BytesSource(zipBytes({'fabric.mod.json': json, 'assets/b.png': tinyPng()})),
      );
      final m = (await readModMeta(jar!))!;
      expect(m.loader, Loader.fabric);
      expect(m.authors, ['alice', 'bob']);
      expect(m.authors.join(', '), 'alice, bob');
      expect(m.homepage, 'https://example.org');
      expect(m.mcVersion, '~1.21');
      expect(m.iconPath, 'assets/b.png');
      expect(await readModIcon(jar, m.iconPath!), isNotNull);
    });

    test('Quilt quilt.mod.json', () async {
      final json = jsonEncode({
        'schema_version': 1,
        'quilt_loader': {
          'id': 'qm',
          'version': '2.0',
          'metadata': {
            'name': 'Quilty',
            'contributors': {'carol': 'Owner'},
            'contact': {'homepage': 'javascript:alert(1)'},
          },
          'depends': [
            {'id': 'minecraft', 'versions': '>=1.20'},
          ],
        },
      });
      final jar = await ZipArchive.open(BytesSource(zipBytes({'quilt.mod.json': json})));
      final m = (await readModMeta(jar!))!;
      expect(m.loader, Loader.quilt);
      expect(m.name, 'Quilty');
      expect(m.authors, ['carol']);
      expect(m.homepage, isNull);
      expect(m.mcVersion, '>=1.20');
    });

    test('icona non PNG o troppo grande: niente; jar rotto o senza metadati: null', () async {
      final jar = await ZipArchive.open(
        BytesSource(zipBytes({'a.png': 'GIF89a', 'b.png': Uint8List(600 << 10)})),
      );
      expect(await readModIcon(jar!, 'a.png'), isNull);
      expect(await readModIcon(jar, 'b.png'), isNull);
      expect(await readModIcon(jar, 'missing.png'), isNull);
      expect(await readModMeta(jar), isNull);
      expect(await ZipArchive.open(BytesSource(Uint8List.fromList(utf8.encode('no zip')))), isNull);
      // metadati enormi compressi: oltre il tetto non si leggono
      final huge = await ZipArchive.open(
        BytesSource(zipBytes({'fabric.mod.json': ' ' * (2 << 20)})),
      );
      expect(await readModMeta(huge!), isNull);
    });

    test('B-META-05 homepage solo http/https', () {
      const cases = {
        'https://example.com/mod': 'https://example.com/mod',
        'http://example.com': 'http://example.com',
        'javascript:alert(1)': null,
        'JavaScript:alert(1)': null,
        'data:text/html,x': null,
        '//evil.example': null,
        'ftp://example.com': null,
        '  https://example.com/  ': 'https://example.com/',
        'not a url': null,
      };
      cases.forEach((input, want) => expect(safeUrl(input), want, reason: input));
      final m = parseFabricJson(
        Uint8List.fromList(utf8.encode('{"id":"x","contact":{"homepage":"javascript:alert(1)"}}')),
      );
      expect(m!.homepage, isNull);
    });
  });

  group('giocatori', () {
    test('statistiche: play_time o play_one_minute, morti, uccisioni, distanza', () {
      final s = parsePlayerStats(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'stats': {
                'minecraft:custom': {
                  'minecraft:play_time': 72000,
                  'minecraft:deaths': 3,
                  'minecraft:mob_kills': 40,
                  'minecraft:walk_one_cm': 1000,
                  'minecraft:sprint_one_cm': 500,
                  'minecraft:swim_one_cm': 20,
                  'minecraft:fly_one_cm': 99999,
                },
              },
              'DataVersion': 3955,
            }),
          ),
        ),
      )!;
      expect(s, (playTicks: 72000, deaths: 3, mobKills: 40, distanceCm: 1520));
      final old = parsePlayerStats(
        Uint8List.fromList(
          utf8.encode('{"stats":{"minecraft:custom":{"minecraft:play_one_minute":20}}}'),
        ),
      )!;
      expect(old.playTicks, 20);
      expect(parsePlayerStats(Uint8List.fromList(utf8.encode('[1]'))), isNull);
    });

    test('usercache, ops e whitelist; uuid normalizzati, voci invalide saltate', () {
      final u = parsePlayerEntries(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode([
              {
                'name': 'alice',
                'uuid': '0123456789ABCDEF0123456789ABCDEF',
                'expiresOn': '2026-12-22 10:00:00 +0100',
              },
              {'name': 'bob', 'uuid': 'nope'},
              {'name': 'carol', 'uuid': '11111111-2222-3333-4444-555555555555', 'level': 4},
              7,
            ]),
          ),
        ),
      );
      expect(u.length, 2);
      expect(u[0].uuid, '01234567-89ab-cdef-0123-456789abcdef');
      expect(u[0].expiresOn, DateTime.utc(2026, 12, 22, 9).millisecondsSinceEpoch);
      expect(
        lastSeenFromExpiry(u[0].expiresOn!),
        DateTime.utc(2026, 11, 22, 9).millisecondsSinceEpoch,
      );
      expect(u[1].level, 4);
      expect(parsePlayerEntries(Uint8List.fromList(utf8.encode('{'))), isEmpty);
    });
  });

  group('server', () {
    test('server.properties: sottoinsieme, motd senza §, chiavi assenti omesse', () {
      final p = serverPropertiesInfo(
        parseProperties(
          'motd=\\u00a7aCiao \\u00a7lmondo\nmax-players=10\npvp=false\nwhite-list=true\n'
          'view-distance=12\nserver-port=25570\nonline-mode=true\n',
        ),
        whitelistCount: 3,
      );
      expect(p.toJson(), {
        'motd': 'Ciao mondo',
        'maxPlayers': 10,
        'pvp': false,
        'whitelist': true,
        'whitelistCount': 3,
        'viewDistance': 12,
        'port': 25570,
        'onlineMode': true,
      });
      expect(serverPropertiesInfo(const {}).toJson(), isEmpty);
    });

    test('cartella del mondo da level-name, valori pericolosi → world', () {
      expect(levelFolder(const {}), 'world');
      expect(levelFolder(const {'level-name': 'Avventura'}), 'Avventura');
      for (final bad in ['../x', '/etc', 'a//b', r'a\b', '']) {
        expect(levelFolder({'level-name': bad}), 'world', reason: bad);
      }
    });

    test('loader e versione dai percorsi', () {
      WorldChip c(List<String> paths, {String? mc}) => chipFromPaths(paths, mcVersion: mc);
      expect(
        c([
          'fabric-server-launch.jar',
          'libraries/net/fabricmc/fabric-loader/0.16.5/fabric-loader-0.16.5.jar',
          'libraries/net/fabricmc/fabric-loader/0.15.0/fabric-loader-0.15.0.jar',
          'mods/a.jar',
          'mods/b.JAR',
          'mods/sub/c.jar',
          'mods/readme.txt',
        ], mc: '1.21.1').toJson(),
        {'mcVersion': '1.21.1', 'loader': 'fabric', 'loaderVersion': '0.16.5', 'mods': 2},
      );
      expect(c(['libraries/net/neoforged/neoforge/21.1.65/x.jar', 'run.sh']).toJson(), {
        'loader': 'neoforge',
        'loaderVersion': '21.1.65',
        'mods': 0,
      });
      expect(
        c([
          'libraries/net/minecraftforge/forge/1.20.1-47.3.0/x.jar',
          'libraries/net/minecraft/server/1.20.1-20230612/server.jar',
        ]).toJson(),
        {'mcVersion': '1.20.1', 'loader': 'forge', 'loaderVersion': '47.3.0', 'mods': 0},
      );
      expect(
        c([
          'quilt-server-launch.jar',
          'libraries/net/fabricmc/x/1/y.jar',
          'libraries/org/quiltmc/quilt-loader/0.26.0/q.jar',
        ]).loader,
        Loader.quilt,
      );
      expect(c(['paper-1.21.1-123.jar']).toJson(), {
        'loader': 'paper',
        'loaderVersion': '123',
        'mods': 0,
      });
      expect(c(['world/level.dat']).loader, Loader.vanilla);
      expect(c(['notes.txt']).loader, isNull);
    });
  });
}
