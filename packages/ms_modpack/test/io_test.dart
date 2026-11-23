// Parte dart:io: download verificati, applicazione dei piani, file del pack,
// cache su disco, installer dei server con trasporto e processi finti.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

/// Trasporto finto per URL completi.
FakeTransport files(Map<String, List<int>> byUrl) => FakeTransport({
  for (final e in byUrl.entries)
    'GET ${Uri.parse(e.key).host}${Uri.parse(e.key).path}': (_) => HttpRes.bytes(200, e.value),
});

final class FakeRunner implements ProcessRunner {
  final calls = <(String, List<String>, String)>[];
  int code = 0;
  void Function(String dir)? effect;

  @override
  Future<int> run(
    String executable,
    List<String> args, {
    required String workingDirectory,
    void Function(String line)? onLine,
  }) async {
    calls.add((executable, args, workingDirectory));
    onLine?.call('installing');
    effect?.call(workingDirectory);
    return code;
  }
}

void main() {
  late Directory tmp;
  setUp(() async => tmp = await Directory.systemTemp.createTemp('ms_modpack_test'));
  tearDown(() async => tmp.delete(recursive: true));

  group('download', () {
    test('verificato per hash; hash sbagliato: il file non resta', () async {
      final body = utf8.encode('hello');
      final t = files({'https://cdn.example/a.jar': body, 'https://cdn.example/b.jar': body});
      final dl = Downloader(t, userAgent: 'minesync/test');
      final dest = p.join(tmp.path, 'mods', 'a.jar');
      final f = await dl.download(
        ['https://cdn.example/a.jar'],
        dest,
        sha1: sha1Of(body),
        sha512: sha512Of(body),
        size: 5,
      );
      expect(f.sha1, sha1Of(body));
      expect(await File(dest).readAsString(), 'hello');
      expect(t.requests.single.headers['User-Agent'], 'minesync/test');
      final bad = p.join(tmp.path, 'mods', 'b.jar');
      await expectLater(
        dl.download(['https://cdn.example/b.jar'], bad, sha1: 'f' * 40),
        throwsA(isA<HashMismatch>()),
      );
      expect(File(bad).existsSync(), isFalse);
      expect(File('$bad.minesyncpart').existsSync(), isFalse);
      await expectLater(
        dl.download(['https://cdn.example/b.jar'], bad, size: 3),
        throwsA(isA<HashMismatch>()),
      );
    });

    test('il secondo URL se il primo non va; tutti falliti', () async {
      final body = utf8.encode('x');
      final t = files({'https://mirror.example/a.jar': body});
      final dl = Downloader(t, userAgent: 'minesync/test');
      final dest = p.join(tmp.path, 'a.jar');
      await dl.download(
        ['https://cdn.example/a.jar', 'https://mirror.example/a.jar'],
        dest,
        sha1: sha1Of(body),
      );
      expect(File(dest).existsSync(), isTrue);
      await expectLater(
        dl.download(['https://none.example/a'], dest),
        throwsA(isA<DownloadFailed>()),
      );
    });
  });

  group('download in un isolate', () {
    late HttpServer server;
    final body = Uint8List.fromList(List.generate(3 << 20, (i) => i * 7 & 0xff));
    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((r) async {
        if (r.uri.path == '/a.jar') {
          r.response.contentLength = body.length;
          r.response.add(body);
        } else {
          r.response.statusCode = 404;
        }
        await r.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('scarica, verifica e riporta l\'avanzamento; errori come senza isolate', () async {
      final dl = Downloader.isolated(userAgent: 'minesync/test');
      final base = 'http://127.0.0.1:${server.port}';
      final dest = p.join(tmp.path, 'a.jar');
      final seen = <int>[];
      final f = await dl.download(
        ['$base/a.jar'],
        dest,
        sha1: sha1Of(body),
        size: body.length,
        onProgress: (r, t) => seen.add(r),
      );
      expect(f.sha1, sha1Of(body));
      expect(f.size, body.length);
      expect(await File(dest).readAsBytes(), body);
      // l'ultimo avanzamento è sempre il totale
      expect(seen.last, body.length);
      await expectLater(
        dl.download(['$base/a.jar'], p.join(tmp.path, 'b.jar'), sha1: 'f' * 40),
        throwsA(isA<HashMismatch>()),
      );
      expect(File(p.join(tmp.path, 'b.jar')).existsSync(), isFalse);
      await expectLater(
        dl.download(['$base/none'], p.join(tmp.path, 'c.jar')),
        throwsA(isA<DownloadFailed>()),
      );
    });
  });

  group('cartella del server', () {
    test('pack su disco, hash dei jar, applicazione del piano', () async {
      final root = tmp.path;
      final aBytes = fakeJar('aPr-1.0.jar');
      final ver = v('aV1', 'aPr', '1.0');
      final a = modFromVersion(ver);
      final t = files({a.downloads.single: aBytes});
      final dl = Downloader(t, userAgent: 'minesync/test');
      // un jar a mano che il pack non conosce resta dov'è
      await File(p.join(root, 'mods', 'other.jar')).create(recursive: true);
      await File(p.join(root, 'mods', 'other.jar')).writeAsString('other');
      final pack = fabricPack([a]);
      expect(await readPackFile(root), isNull);
      final plan = planInstall(to: pack, files: await scanModFiles(root));
      final r = await applyInstallPlan(root, plan, dl);
      expect(r.downloaded, 1);
      expect(await File(p.join(root, 'mods', 'aPr-1.0.jar')).readAsBytes(), aBytes);
      expect(File(p.join(root, 'mods', 'other.jar')).existsSync(), isTrue);
      expect(Directory(p.join(root, modpackTmpDir)).existsSync(), isFalse);
      expect(await readPackFile(root), pack);
      expect(await File(p.join(root, packFileName)).readAsString(), pack.encode());

      final scan = await scanModFiles(root);
      expect([for (final f in scan) f.path], ['mods/aPr-1.0.jar', 'mods/other.jar']);
      final check = checkPack(pack, scan);
      expect(check.isClean, isFalse);
      expect(check.untracked.single.path, 'mods/other.jar');
      expect(manualEntry(check.untracked.single).sha512, isNotNull);

      // spegnerla: un rename, niente rete
      final off = fabricPack([a.copyWith(disabled: true)]);
      final plan2 = planInstall(from: pack, to: off, files: await scanModFiles(root));
      await applyInstallPlan(root, plan2, dl);
      expect(File(p.join(root, 'mods', 'aPr-1.0.jar.disabled')).existsSync(), isTrue);
      expect(t.requests.length, 1);
    });

    test('un download sbagliato non tocca niente', () async {
      final root = tmp.path;
      final a = modFromVersion(v('aV1', 'aPr', '1.0'));
      final b = modFromVersion(v('bV1', 'bPr', '1.0'));
      final t = files({
        a.downloads.single: fakeJar('aPr-1.0.jar'),
        b.downloads.single: utf8.encode('corrupt'),
      });
      final plan = planInstall(to: fabricPack([a, b]), files: const []);
      await expectLater(
        applyInstallPlan(root, plan, Downloader(t, userAgent: 'x')),
        throwsA(isA<HashMismatch>()),
      );
      expect(File(p.join(root, 'mods', 'aPr-1.0.jar')).existsSync(), isFalse);
      expect(File(p.join(root, packFileName)).existsSync(), isFalse);
      expect(Directory(p.join(root, modpackTmpDir)).existsSync(), isFalse);
    });

    test('percorsi fuori dalla radice rifiutati', () {
      expect(() => insideRoot(tmp.path, '../x'), throwsArgumentError);
      expect(() => insideRoot(tmp.path, '/etc/passwd'), throwsArgumentError);
      expect(insideRoot(tmp.path, 'mods/a.jar'), p.join(tmp.path, 'mods', 'a.jar'));
    });

    test('import di un .mrpack su disco e export del pacchetto', () async {
      final root = tmp.path;
      final a = modFromVersion(v('aV1', 'aPr', '1.0'));
      final plan0 = planClientPack(
        fabricPack([a]).copyWith(shared: ['config/**']),
        const [],
        versionId: '1',
      );
      final src = <String, Uint8List>{'config/x.toml': Uint8List.fromList(utf8.encode('k=v'))};
      final withCfg = planClientPack(
        fabricPack([a]).copyWith(shared: ['config/**']),
        src.keys,
        versionId: '1',
      );
      expect(plan0.overrides, isEmpty);
      final mr = p.join(tmp.path, 'in.mrpack');
      await File(mr).writeAsBytes(writeMrpack(withCfg, (s) => src[s]));
      final imp = await readMrpackFile(mr, name: 'Avventura');
      final server = p.join(root, 'server');
      await writeImportFiles(server, imp);
      expect(await File(p.join(server, 'config', 'x.toml')).readAsString(), 'k=v');
      final t = files({a.downloads.single: fakeJar('aPr-1.0.jar')});
      await applyInstallPlan(
        server,
        planInstall(to: imp.pack, files: const []),
        Downloader(t, userAgent: 'x'),
      );
      expect((await readPackFile(server))!.name, 'Avventura');
      final out = p.join(tmp.path, 'out.mrpack');
      final plan = await exportClientMrpack(server, imp.pack, out, versionId: '2');
      expect(plan.overrides.single.zipPath, 'overrides/config/x.toml');
      final back = await readMrpackFile(out);
      expect(back.pack.byProject('aPr'), isNotNull);
      expect(await listServerFiles(server), [
        'config/x.toml',
        'minesync-pack.json',
        'mods/aPr-1.0.jar',
      ]);
    });
  });

  test('cache su disco: andata e ritorno, chiave diversa = mancato colpo', () async {
    final c = FileResponseCache(p.join(tmp.path, 'cache'), maxEntries: 2);
    await c.put('GET a', CachedBody(Uint8List.fromList([1, 2]), 99));
    final hit = await c.get('GET a');
    expect(hit!.body, [1, 2]);
    expect(hit.expiresAtMs, 99);
    expect(await c.get('GET b'), isNull);
  });

  group('installer dei server', () {
    final serverJar = utf8.encode('vanilla server');
    Map<String, Handler> mojang() => {
      'GET piston-meta.mojang.com/mc/game/version_manifest_v2.json': (_) => json({
        'latest': {'release': '1.21.1', 'snapshot': '24w99a'},
        'versions': [
          {
            'id': '1.21.1',
            'type': 'release',
            'url':
                'https://piston-meta.mojang.com/v1/packages/${sha1Of(_versionJson(serverJar))}/1.21.1.json',
            'time': '2026-01-01T00:00:00+00:00',
            'releaseTime': '2026-01-01T00:00:00+00:00',
            'sha1': sha1Of(_versionJson(serverJar)),
            'complianceLevel': 1,
          },
        ],
      }),
      'GET piston-meta.mojang.com/v1/packages/*': (_) =>
          HttpRes.bytes(200, _versionJson(serverJar)),
      'GET piston-data.mojang.com/v1/objects/*': (_) => HttpRes.bytes(200, serverJar),
    };

    test('vanilla: server.jar verificato, Java da Mojang, EULA solo con il clic', () async {
      final t = FakeTransport(mojang());
      final inst = ServerInstaller(Downloader(t, userAgent: 'x'), runner: FakeRunner());
      final dir = p.join(tmp.path, 'srv');
      final r = await inst.install(
        ServerInstallRequest(dir: dir, mcVersion: '1.21.1', loader: Loader.vanilla),
      );
      expect(r.launchJar, 'server.jar');
      expect(r.javaMajor, 21);
      expect(r.eulaWritten, isFalse);
      expect(File(p.join(dir, 'eula.txt')).existsSync(), isFalse);
      expect(await File(p.join(dir, 'server.jar')).readAsBytes(), serverJar);
      final r2 = await inst.install(
        ServerInstallRequest(
          dir: dir,
          mcVersion: '1.21.1',
          loader: Loader.vanilla,
          acceptEula: true,
        ),
      );
      expect(r2.eulaWritten, isTrue);
      expect(await File(p.join(dir, 'eula.txt')).readAsString(), contains('eula=true'));
      expect(await inst.latestRelease(), '1.21.1');
      await expectLater(
        inst.install(ServerInstallRequest(dir: dir, mcVersion: '9.9', loader: Loader.vanilla)),
        throwsA(isA<InstallFailed>()),
      );
    });

    test('vanilla: JSON della versione manomesso → errore di hash', () async {
      final routes = mojang()
        ..['GET piston-meta.mojang.com/v1/packages/*'] = (_) =>
            HttpRes.bytes(200, utf8.encode('{"tampered":1}'));
      final inst = ServerInstaller(Downloader(FakeTransport(routes), userAgent: 'x'));
      await expectLater(
        inst.install(
          ServerInstallRequest(dir: tmp.path, mcVersion: '1.21.1', loader: Loader.vanilla),
        ),
        throwsA(isA<HashMismatch>()),
      );
    });

    test('Fabric: launcher dalla meta API con l\'ultima stabile', () async {
      final t = FakeTransport({
        ...mojang(),
        'GET meta.fabricmc.net/v2/versions/loader/1.21.1': (_) => json([
          {
            'loader': {'version': '0.17.0-beta.1', 'stable': false},
          },
          {
            'loader': {'version': '0.16.14', 'stable': true},
          },
        ]),
        'GET meta.fabricmc.net/v2/versions/installer': (_) => json([
          {'url': 'https://maven.fabricmc.net/x.jar', 'version': '1.1.0', 'stable': true},
        ]),
        'GET meta.fabricmc.net/v2/versions/loader/1.21.1/0.16.14/1.1.0/server/jar': (_) =>
            HttpRes.bytes(200, utf8.encode('fabric launcher')),
      });
      final inst = ServerInstaller(Downloader(t, userAgent: 'x'));
      final r = await inst.install(
        ServerInstallRequest(dir: tmp.path, mcVersion: '1.21.1', loader: Loader.fabric),
      );
      expect(r.loaderVersion, '0.16.14');
      expect(r.launchJar, 'fabric-server-launch.jar');
      expect(File(p.join(tmp.path, 'fabric-server-launch.jar')).existsSync(), isTrue);
    });

    test('NeoForge: installer verificato con .sha1 e lanciato con il Java dato', () async {
      final jar = utf8.encode('neoforge installer');
      final t = FakeTransport({
        ...mojang(),
        'GET maven.neoforged.net/releases/net/neoforged/neoforge/21.1.77/neoforge-21.1.77-installer.jar.sha1':
            (_) => HttpRes.bytes(200, utf8.encode(sha1Of(jar))),
        'GET maven.neoforged.net/releases/net/neoforged/neoforge/21.1.77/neoforge-21.1.77-installer.jar':
            (_) => HttpRes.bytes(200, jar),
      });
      final run = FakeRunner();
      final inst = ServerInstaller(Downloader(t, userAgent: 'x'), runner: run);
      final req = ServerInstallRequest(
        dir: tmp.path,
        mcVersion: '1.21.1',
        loader: Loader.neoforge,
        loaderVersion: '21.1.77',
        javaPath: '/opt/java21/bin/java',
      );
      final r = await inst.install(req);
      final call = run.calls.single;
      expect(call.$1, '/opt/java21/bin/java');
      expect(call.$2.sublist(2), ['--installServer', tmp.path]);
      expect(r.launchJar, Platform.isWindows ? 'run.bat' : 'run.sh');
      // l'installer scaricato non resta nella cartella
      expect(
        Directory(tmp.path).listSync().map((e) => p.basename(e.path)),
        isNot(contains(startsWith('.minesync'))),
      );
      run.code = 1;
      await expectLater(
        inst.install(req),
        throwsA(isA<InstallFailed>().having((e) => e.step, 'step', 'installer')),
      );
      await expectLater(
        inst.install(
          ServerInstallRequest(
            dir: tmp.path,
            mcVersion: '1.21.1',
            loader: Loader.forge,
            loaderVersion: '52.0.40',
          ),
        ),
        throwsA(isA<InstallFailed>().having((e) => e.step, 'step', 'java')),
      );
    });

    test('Forge e NeoForge: versioni per Minecraft', () async {
      final t = FakeTransport({
        'GET files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json': (_) => json({
          'homepage': 'https://files.minecraftforge.net/',
          'promos': {'1.21.1-latest': '52.0.45', '1.21.1-recommended': '52.0.40'},
        }),
        'GET maven.neoforged.net/api/maven/versions/releases/net/neoforged/neoforge': (_) => json({
          'isSnapshot': false,
          'versions': ['21.0.10', '21.1.70', '21.1.77', '21.4.1-beta'],
        }),
      });
      final inst = ServerInstaller(Downloader(t, userAgent: 'x'));
      expect(await inst.loaderVersions(Loader.forge, '1.21.1'), [
        ('52.0.40', true),
        ('52.0.45', false),
      ]);
      expect(await inst.loaderVersions(Loader.neoforge, '1.21.1'), [
        ('21.1.77', true),
        ('21.1.70', true),
      ]);
    });

    test('prefisso delle versioni NeoForge', () {
      expect(neoforgePrefix('1.21.1'), '21.1.');
      expect(neoforgePrefix('1.21'), '21.0.');
      expect(neoforgePrefix('1.20.4'), '20.4.');
      expect(neoforgePrefix('1.19.2'), isNull);
      expect(neoforgePrefix('26.1'), '26.1.0.');
      expect(neoforgePrefix('26.1.2'), '26.1.2.');
      expect(neoforgePrefix('abc'), isNull);
    });
  });
}

/// JSON di una versione di Mojang (forma del manifest v2, dati inventati).
List<int> _versionJson(List<int> serverJar) => utf8.encode(
  jsonEncode({
    'id': '1.21.1',
    'type': 'release',
    'javaVersion': {'component': 'java-runtime-delta', 'majorVersion': 21},
    'downloads': {
      'server': {
        'sha1': sha1Of(serverJar),
        'size': serverJar.length,
        'url': 'https://piston-data.mojang.com/v1/objects/${sha1Of(serverJar)}/server.jar',
      },
    },
  }),
);
