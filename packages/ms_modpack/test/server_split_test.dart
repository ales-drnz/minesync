// Server da un modpack solo per i giocatori: divisione delle voci fra server
// e giocatori (env dell'indice, lato su Modrinth, environment del jar,
// resource pack), sconosciute decise dall'admin, jar degli override spostati
// sotto client-overrides/, risoluzione con Modrinth finto o assente.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:test/test.dart';

import 'mrpack_test.dart' show fileEntry, index, mrpack;
import 'support.dart';

/// Un jar con un fabric.mod.json che dichiara [env].
Uint8List fabricJar(String id, String env) {
  final a = Archive()
    ..add(
      ArchiveFile.bytes(
        'fabric.mod.json',
        utf8.encode(jsonEncode({'schemaVersion': 1, 'id': id, 'environment': env})),
      ),
    );
  return ZipEncoder().encodeBytes(a);
}

String cdn(String project, String file) =>
    'https://cdn.modrinth.com/data/$project/versions/vers0001/$file';

/// Un pack «solo client»: env dove c'è, mod senza env, jar negli override.
MrpackImport clientPack() => readMrpack(
  mrpack(
    index(
      files: [
        // env dell'indice
        fileEntry('mods/sodium.jar', client: 'required', server: 'unsupported'),
        fileEntry('mods/chunky.jar', client: 'unsupported', server: 'required'),
        fileEntry('mods/cobble.jar', client: 'required', server: 'required'),
        // senza env: decide Modrinth
        fileEntry('mods/iris.jar', url: cdn('irisPrjx', 'iris.jar')),
        fileEntry('mods/lithium.jar', url: cdn('lithiumx', 'lithium.jar')),
        // senza env e sconosciuto a Modrinth
        fileEntry('mods/mystery.jar', url: cdn('mysteryx', 'mystery.jar')),
        // env dice server ma Modrinth dice che sul server non va
        fileEntry(
          'mods/menu.jar',
          url: cdn('menuPrjx', 'menu.jar'),
          client: 'required',
          server: 'required',
        ),
        // resource pack senza env
        fileEntry('resourcepacks/faithful.zip', url: cdn('faithful', 'faithful.zip')),
      ],
    ),
    {
      'overrides/mods/zoom.jar': fabricJar('zoom', 'client'),
      'overrides/mods/tweaks.jar': fabricJar('tweaks', '*'),
      'overrides/mods/plain.jar': utf8.encode('not a zip'),
      'overrides/config/cobble.json': utf8.encode('{}'),
      'server-overrides/mods/backup.jar': utf8.encode('backup'),
    },
  ),
);

Map<String, String> serverSides() => {
  'irisPrjx': 'unsupported',
  'lithiumx': 'optional',
  'menuPrjx': 'unsupported',
};

Map<String, MrProject> projects() => {
  for (final e in serverSides().entries) e.key: proj(e.key, server: e.value),
};

void main() {
  test('jarEnvironment: fabric.mod.json, quilt.mod.json, jar illeggibile', () {
    expect(jarEnvironment(fabricJar('a', 'client')), 'client');
    expect(jarEnvironment(fabricJar('a', '*')), '*');
    final q = Archive()
      ..add(
        ArchiveFile.bytes(
          'quilt.mod.json',
          utf8.encode(
            jsonEncode({
              'quilt_loader': {'id': 'q'},
              'minecraft': {'environment': 'client'},
            }),
          ),
        ),
      );
    expect(jarEnvironment(ZipEncoder().encodeBytes(q)), 'client');
    expect(jarEnvironment(utf8.encode('nope')), isNull);
    expect(jarEnvironment(ZipEncoder().encodeBytes(Archive())), isNull);
  });

  test('divisione: indice, Modrinth, jar, resource pack, sconosciute', () {
    final sp = splitForServer(clientPack(), projects: projects());
    String fate(String path) {
      final e = sp.entries.singleWhere((e) => e.mod.path == path);
      return '${e.fate.name}/${e.reason.name}';
    }

    expect(fate('mods/sodium.jar'), 'clientOnly/packIndex');
    expect(fate('mods/chunky.jar'), 'server/packIndex');
    expect(fate('mods/cobble.jar'), 'server/packIndex');
    expect(fate('mods/iris.jar'), 'clientOnly/modrinth');
    expect(fate('mods/lithium.jar'), 'server/modrinth');
    expect(fate('mods/mystery.jar'), 'unknown/none');
    expect(fate('mods/menu.jar'), 'clientOnly/modrinth');
    expect(fate('resourcepacks/faithful.zip'), 'clientOnly/clientContent');
    expect(fate('mods/zoom.jar'), 'clientOnly/jar');
    expect(fate('mods/tweaks.jar'), 'server/jar');
    expect(fate('mods/plain.jar'), 'unknown/none');
    expect(fate('mods/backup.jar'), 'server/packIndex');
    expect(sp.onServer.length, 5);
    expect(sp.clientOnly.length, 5);
    expect(sp.unknown.map((e) => e.mod.file), ['mystery.jar', 'plain.jar']);
    // i nomi dei progetti trovati restano
    expect(sp.entries.singleWhere((e) => e.mod.path == 'mods/iris.jar').name, 'irisPrjx');
  });

  test('applicata: lato client, jar degli override sotto client-overrides/, sconosciute', () {
    final sp = splitForServer(clientPack(), projects: projects());
    final mystery = sp.unknown.singleWhere((e) => e.mod.file == 'mystery.jar');
    expect(sp.serverCount(const {}), 7);
    expect(sp.clientCount({mystery.key}), 6);

    // di base le sconosciute restano sul server
    final keep = sp.apply();
    expect(keep.pack.byPath('mods/mystery.jar')!.side, PackSide.both);
    expect(keep.pack.byPath('mods/plain.jar')!.side, PackSide.both);
    expect(keep.pack.byPath('mods/iris.jar')!.side, PackSide.client);
    expect(keep.pack.byPath('mods/iris.jar')!.location, 'client-overrides/mods/iris.jar');
    expect(keep.pack.byPath('mods/menu.jar')!.side, PackSide.client);
    expect(keep.pack.byPath('resourcepacks/faithful.zip')!.side, PackSide.client);
    final paths = keep.files.map((f) => f.path).toList();
    expect(paths, contains('client-overrides/mods/zoom.jar'));
    expect(paths, isNot(contains('mods/zoom.jar')));
    expect(paths, containsAll(['mods/tweaks.jar', 'mods/plain.jar', 'mods/backup.jar']));
    expect(paths, contains('config/cobble.json'));

    // l'admin toglie dal server quella sconosciuta
    final out = sp.apply(excluded: {mystery.key});
    expect(out.pack.byPath('mods/mystery.jar')!.side, PackSide.client);
    // sul server installa solo quel che resta
    final plan = planInstall(to: out.pack, files: const []);
    final locations = plan.downloads.map((d) => d.location).toList();
    expect(locations, isNot(contains('mods/iris.jar')));
    expect(locations, isNot(contains('mods/mystery.jar')));
    expect(locations, contains('mods/lithium.jar'));
    expect(locations, contains('client-overrides/mods/sodium.jar'));
    // il pacchetto per i giocatori ha ancora le mod solo client
    final cp = planClientPack(out.pack, [for (final f in out.files) f.path], versionId: '1');
    expect(cp.index.files.map((f) => f.path), containsAll(['mods/sodium.jar', 'mods/iris.jar']));
    expect(cp.overrides.map((o) => o.zipPath), contains('client-overrides/mods/zoom.jar'));
  });

  group('con Modrinth', () {
    test('progetti per id, file sconosciuti per hash', () async {
      final t = FakeTransport();
      final plain = utf8.encode('not a zip');
      t.routes['POST api.modrinth.com/v2/version_files'] = (r) {
        final body = jsonDecode(utf8.decode(r.body!)) as Map<String, Object?>;
        final hashes = (body['hashes']! as List).cast<String>();
        return json({
          if (hashes.contains(sha1Of(plain)))
            sha1Of(plain): versionJson(id: 'plainVer', project: 'plainPrj', number: '1'),
        });
      };
      t.routes['GET api.modrinth.com/v2/projects'] = (r) {
        final ids = (jsonDecode(r.url.queryParameters['ids']!) as List).cast<String>();
        final all = {
          for (final e in serverSides().entries) e.key: projectJson(e.key, server: e.value),
          'plainPrj': projectJson('plainPrj', title: 'Plain', server: 'unsupported'),
        };
        return json([for (final i in ids) ?all[i]]);
      };
      final sp = await resolveServerSplit(
        clientPack(),
        ModrinthClient(transport: t, userAgent: 'test', sleep: (_) async {}),
      );
      final plainE = sp.entries.singleWhere((e) => e.mod.file == 'plain.jar');
      expect(
        (plainE.fate, plainE.reason, plainE.name),
        (SplitFate.clientOnly, SplitReason.modrinth, 'Plain'),
      );
      expect(sp.unknown.map((e) => e.mod.file), ['mystery.jar']);
      final req = t.requests.singleWhere((r) => r.url.path.endsWith('/projects'));
      expect(
        jsonDecode(req.url.queryParameters['ids']!),
        containsAll(['irisPrjx', 'lithiumx', 'menuPrjx', 'mysteryx', 'plainPrj']),
      );
    });

    test('Modrinth non risponde: si divide con l\'indice e i jar', () async {
      final t = FakeTransport();
      t.routes['POST api.modrinth.com/v2/version_files'] = (r) => throw HttpUnavailable(r.url, 'x');
      t.routes['GET api.modrinth.com/v2/projects'] = (r) => throw HttpUnavailable(r.url, 'x');
      final sp = await resolveServerSplit(
        clientPack(),
        ModrinthClient(transport: t, userAgent: 'test', sleep: (_) async {}, maxRetries: 0),
      );
      expect(sp.unknown.map((e) => e.mod.file), [
        'iris.jar',
        'lithium.jar',
        'mystery.jar',
        'plain.jar',
      ]);
      // menu.jar ha env nell'indice: senza Modrinth resta sul server
      expect(sp.onServer.map((e) => e.mod.file), contains('menu.jar'));
      expect(sp.clientOnly.map((e) => e.mod.file), containsAll(['sodium.jar', 'zoom.jar']));
    });
  });
}
