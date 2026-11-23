// Controller del modpack contro l'hub vero in-process e un Modrinth finto:
// riconoscimento dei jar al primo uso, applicazione (tutto scaricato e
// verificato prima, poi il caricamento normale), download fallito che non
// tocca la cartella, coda mentre qualcuno gioca, aggiornamenti, cambio di
// versione, pacchetto per i giocatori e profilo del launcher ufficiale.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/launcher_profile.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_minecraft/ms_minecraft.dart';
import 'package:ms_modpack/io.dart';
import 'package:ms_modpack/ms_modpack.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:path/path.dart' as p;

import 'support/modpack_fakes.dart';
import 'support/space_fakes.dart';

Future<void> until(bool Function() ok, {Duration max = const Duration(seconds: 10)}) async {
  final sw = Stopwatch()..start();
  while (!ok()) {
    if (sw.elapsed > max) throw TimeoutException('condizione non raggiunta');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

const _create = 'AAAAAAAA';
const _balm = 'BBBBBBBB';
const _way = 'CCCCCCCC';

FakeModrinth _modrinth() => FakeModrinth()
  ..addProject(projectJson(_create, title: 'Create'), [
    versionJson(id: 'AV100000', project: _create, number: '6.0.6', filename: 'create-6.0.6.jar'),
    versionJson(
      id: 'AV200000',
      project: _create,
      number: '6.0.8',
      date: '2026-03-01T00:00:00Z',
      filename: 'create-6.0.8.jar',
    ),
    versionJson(
      id: 'AV300000',
      project: _create,
      number: '6.1.0',
      game: ['1.21.4'],
      date: '2026-04-01T00:00:00Z',
      filename: 'create-6.1.0.jar',
    ),
  ])
  ..addProject(projectJson(_balm, title: 'Balm'), [
    versionJson(id: 'BV100000', project: _balm, number: '21.0.46', filename: 'balm-21.0.46.jar'),
  ])
  ..addProject(projectJson(_way, title: 'Waystones'), [
    versionJson(
      id: 'CV100000',
      project: _way,
      number: '21.1.25',
      filename: 'waystones-21.1.25.jar',
      deps: [dep(_balm)],
    ),
  ]);

/// Sonde finte con future veri: SynchronousFuture.catchError non finisce
/// mai, e il caricamento rilegge la cartella con catchError.
class _AsyncProbe extends FakeLocalProbe {
  const _AsyncProbe({super.scans});

  @override
  Future<LocalScan> scan(String folder) => Future.value(scans[folder] ?? const LocalScan());

  @override
  Future<List<JavaRuntime>> java({String? serverRoot}) async => sampleJavas;
}

void main() {
  late Directory tmp;
  late Hub hub;
  late AppState app;
  late FakeModrinth mr;
  late FakeTransport transport;
  late FakeTools tools;
  late String folder;
  late String id;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ms_modpack');
    hub = await Hub.start(
      HubConfig(
        dataDir: '${tmp.path}/data',
        address: InternetAddress.loopbackIPv4,
        port: 0,
        devUser: 'alice',
        admins: const ['alice'],
        keepAlive: const Duration(milliseconds: 200),
      ),
      log: (_) {},
    );
    mr = _modrinth();
    transport = FakeTransport(mr.routes);
    tools = FakeTools(downloadsDir: '${tmp.path}/downloads');
    Directory(tools.downloadsDir).createSync();
    app = AppState(
      AppDeps(
        configDir: '${tmp.path}/config',
        platform: PlatformServices.inert(),
        pollEvery: const Duration(milliseconds: 300),
        retryEvery: const Duration(milliseconds: 200),
        // la cartella dei mondi nella cartella temporanea, mai in quella vera
        env: {'HOME': tmp.path},
        modpack: fakeModpackEnv(transport: transport, tools: tools),
      ),
    );
    await app.connectTo('127.0.0.1:${hub.port}');
    id = (await app.createSpace('Survival', Profile.minecraft)).id;
    folder = p.join(tmp.path, 'survival');
    app.localProbe = _AsyncProbe(
      scans: {
        folder: LocalScan(
          exists: true,
          layout: ServerLayout(
            workDir: folder,
            label: 'Fabric',
            mcVersion: '1.21.1',
            loader: 'fabric',
            loaderVersion: '0.16.14',
          ),
        ),
      },
    );
    await app.spaceState(id).linkTo(folder);
  });

  tearDown(() async {
    app.dispose();
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  void put(String rel, List<int> bytes) {
    final f = File(p.join(folder, rel));
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(bytes);
  }

  List<String> files() =>
      [
          for (final e in Directory(folder).listSync(recursive: true))
            if (e is File) p.relative(e.path, from: folder).replaceAll(r'\', '/'),
        ]
        ..removeWhere((f) => f.startsWith('.minesync'))
        ..sort();

  test(
    'primo uso: i jar riconosciuti per SHA-1 diventano mod Modrinth, gli altri voci a mano',
    () async {
      put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
      put('mods/home.jar', utf8.encode('fatta in casa'));
      put('client-overrides/mods/zoom.jar', utf8.encode('zoom'));
      final mp = app.modpack(id);
      await mp.load();
      expect(mp.phase, PackPhase.ready);
      expect(mp.packIsNew, isTrue);
      final b = mp.base!;
      expect(b.mcVersion, '1.21.1');
      expect(b.loader, Loader.fabric);
      final create = b.byProject(_create)!;
      expect(create.source, PackSource.modrinth);
      expect(create.versionId, 'AV100000');
      expect(create.name, 'Create');
      expect(create.side, PackSide.both);
      final home = b.byPath('mods/home.jar')!;
      expect(home.source, PackSource.manual);
      expect(home.side, PackSide.server, reason: 'di default solo server');
      expect(b.byPath('mods/zoom.jar')!.side, PackSide.client);
      // il file del pack non è ancora scritto: si scrive applicando
      expect(File(p.join(folder, packFileName)).existsSync(), isFalse);
      expect(mp.changeCount, 1);
    },
  );

  test(
    'applica: dipendenze aggiunte, mod spenta, pack scritto e nuova generazione sull\'hub',
    () async {
      put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
      put('mods/home.jar', utf8.encode('fatta in casa'));
      final mp = app.modpack(id);
      await mp.load();
      final plan = await mp.planAddition(_way);
      expect(plan.ok, isTrue);
      expect(plan.dependencies.map((m) => m.projectId), [_balm]);
      mp
        ..add(plan)
        ..toggle('path:mods/home.jar');
      expect(mp.changes!.added, hasLength(2));
      final r = await mp.apply();
      expect(r, isA<ApplyDone>().having((d) => d.n, 'n', 1));
      expect(files(), [
        'minesync-pack.json',
        'mods/balm-21.0.46.jar',
        'mods/create-6.0.6.jar',
        'mods/home.jar.disabled',
        'mods/waystones-21.1.25.jar',
      ]);
      final g = await app.client!.generation(id);
      expect(g.n, 1);
      expect(g.manifest.files.keys, contains('minesync-pack.json'));
      expect(mp.dirty, isFalse);
      expect(mp.packIsNew, isFalse);
      final onDisk = await readPackFile(folder);
      expect(onDisk!.byProject(_way)!.versionId, 'CV100000');
      expect(onDisk.byPath('mods/home.jar')!.disabled, isTrue);
    },
  );

  test('download fallito: la cartella non cambia e niente va sull\'hub', () async {
    put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
    final mp = app.modpack(id);
    await mp.load();
    final before = files();
    final plan = await mp.planAddition(_way);
    mp.add(plan);
    // il CDN perde il file di Balm
    mr.cdn.removeWhere((k, _) => k.contains(_balm));
    final r = await mp.apply();
    expect(r, isA<ApplyFailed>().having((f) => f.reason, 'reason', 'download'));
    expect(files(), before);
    expect(Directory(p.join(folder, modpackTmpDir)).existsSync(), isFalse);
    expect((await app.client!.generation(id)).n, 0);
    expect(mp.dirty, isTrue, reason: 'le modifiche restano pronte');
  });

  test('mentre qualcuno gioca: applica rifiutato, in coda e applicato quando si libera', () async {
    put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
    final mp = app.modpack(id);
    await mp.load();
    mp.toggle('mr:$_create');
    final other = HubClient(Uri.parse('http://127.0.0.1:${hub.port}/'));
    addTearDown(other.close);
    final lock = await other.acquireLock(id, const LockInfo(client: 'test', action: 'play'));
    await app.refreshSpaces();
    expect(mp.locked, isTrue);
    final r = await mp.apply();
    expect(r, isA<ApplyFailed>().having((f) => f.reason, 'reason', 'locked'));
    expect(files(), ['mods/create-6.0.6.jar']);
    mp.queueApply(true);
    expect(mp.queued, isTrue);
    expect(mp.applyState, isA<ApplyQueued>());
    await other.releaseLock(id, lock.token);
    await app.refreshSpaces();
    await until(() => mp.applyState is ApplyDone);
    expect(files(), ['minesync-pack.json', 'mods/create-6.0.6.jar.disabled']);
    final notes = app.deps.platform.notifications as InertNotifications;
    expect(notes.shown.map((n) => n.$2), contains(contains('applicazione')));
  });

  test('aggiornamenti: «Aggiorna tutte» mette la versione nuova nelle modifiche', () async {
    put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
    final mp = app.modpack(id);
    await mp.load();
    await mp.checkUpdates();
    final u = mp.pendingUpdates.single;
    expect(u.status, UpdateStatus.available);
    expect(u.latest!.versionNumber, '6.0.8');
    mp.updateAll();
    expect(mp.updateQueued('mr:$_create'), isTrue);
    expect(mp.changes!.updated.single.$2.versionId, 'AV200000');
  });

  test('cambio di versione: le pronte passano alla versione nuova, le bloccate escono', () async {
    put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
    put('mods/balm-21.0.46.jar', fakeJar('balm-21.0.46.jar'));
    final mp = app.modpack(id);
    await mp.load();
    final r = await mp.checkRetarget('1.21.4', Loader.fabric, '0.16.14');
    expect(r.ready.map((e) => e.mod.projectId), [_create]);
    expect(r.blocked.map((e) => e.mod.projectId), [_balm]);
    mp.retarget(r);
    final d = mp.draft!;
    expect(d.mcVersion, '1.21.4');
    expect(d.byProject(_create)!.versionId, 'AV300000');
    expect(d.byProject(_balm), isNull);
    expect(mp.changes!.mcVersion, ('1.21.1', '1.21.4'));
  });

  test('Modrinth irraggiungibile: le mod restano, la ricerca dice perché è vuota', () async {
    put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
    final mp = app.modpack(id);
    await mp.load();
    transport.offline = true;
    await mp.search('waystones');
    expect(mp.modrinthDown, isTrue);
    expect(mp.results, isEmpty);
    expect(mp.base!.mods, hasLength(1));
    transport.offline = false;
    mr.hits.add(hitJson(_way, title: 'Waystones'));
    await mp.retryModrinth();
    expect(mp.modrinthDown, isFalse);
    expect(mp.results.single.fits, isTrue);
  });

  test(
    'pacchetto per i giocatori: .mrpack nella cartella Download e generazione ricordata',
    () async {
      put('mods/create-6.0.6.jar', fakeJar('create-6.0.6.jar'));
      final mp = app.modpack(id);
      await mp.load();
      mp.toggle('mr:$_create');
      mp.toggle('mr:$_create');
      // il pack nuovo si scrive applicando: poi la copia è alla testa
      await mp.apply();
      expect(mp.clientReady, isTrue);
      final out = await mp.exportMrpack();
      expect(out, p.join(tools.downloadsDir, 'Survival-1.mrpack'));
      final imp = await readMrpackFile(out!);
      expect(imp.index.files.single.path, 'mods/create-6.0.6.jar');
      expect(mp.clientInstall!.n, 1);
      expect(mp.clientSnapshot, mp.base);
    },
  );

  test(
    'profilo del launcher ufficiale: copia del file, profilo con cartella sua, mod verificate',
    () async {
      final launcher = Directory(p.join(tmp.path, '.minecraft'))..createSync();
      final profiles = File(p.join(launcher.path, launcherProfilesFile))
        ..writeAsStringSync(
          jsonEncode({
            'profiles': {
              'abc': {'name': 'Mio', 'type': 'custom', 'lastVersionId': '1.21.1'},
            },
            'settings': {'keepLauncherOpen': true},
          }),
        );
      transport.routes['GET meta.fabricmc.net/v2/versions/loader/1.21.1/0.16.14/profile/json'] =
          (_) => jsonRes({
            'id': 'x',
            'inheritsFrom': '1.21.1',
            'mainClass': 'net.fabricmc.loader.Main',
          });
      final pack = Pack(
        name: 'Survival',
        mcVersion: '1.21.1',
        loader: Loader.fabric,
        loaderVersion: '0.16.14',
        mods: [
          PackMod(
            path: 'mods/create-6.0.6.jar',
            name: 'Create',
            sha1: sha1Of(fakeJar('create-6.0.6.jar')),
            sha512: sha512Of(fakeJar('create-6.0.6.jar')),
            size: fakeJar('create-6.0.6.jar').length,
            side: PackSide.both,
            source: PackSource.modrinth,
            projectId: _create,
            versionId: 'AV100000',
            downloads: [
              'https://cdn.modrinth.com/data/$_create/versions/AV100000/create-6.0.6.jar',
            ],
          ),
        ],
      );
      final plan = planClientPack(pack, const [], versionId: '3');
      final r = await createLauncherProfile(
        launcherDir: launcher.path,
        spaceId: 'survival',
        displayName: 'Survival',
        plan: plan,
        serverRoot: folder,
        dl: app.modpackEnv.downloader,
        now: sampleNow,
      );
      expect(r.versionId, 'fabric-loader-0.16.14-1.21.1');
      expect(File(r.backup).existsSync(), isTrue);
      final j = jsonDecode(profiles.readAsStringSync()) as Map<String, Object?>;
      final all = j['profiles']! as Map<String, Object?>;
      expect(all.keys, containsAll(['abc', 'minesync-survival']));
      final prof = all['minesync-survival']! as Map<String, Object?>;
      expect(prof['name'], 'MineSync (Survival)');
      expect(prof['lastVersionId'], 'fabric-loader-0.16.14-1.21.1');
      expect(prof['gameDir'], p.join(launcher.path, 'minesync', 'survival'));
      expect((j['settings']! as Map)['keepLauncherOpen'], isTrue);
      expect(
        File(p.join(r.gameDir, 'mods', 'create-6.0.6.jar')).readAsBytesSync(),
        fakeJar('create-6.0.6.jar'),
      );
      final vj = File(p.join(launcher.path, 'versions', r.versionId, '${r.versionId}.json'));
      expect((jsonDecode(vj.readAsStringSync()) as Map)['id'], r.versionId);
      // senza launcher non si scrive niente
      await expectLater(
        createLauncherProfile(
          launcherDir: p.join(tmp.path, 'nessuno'),
          spaceId: 'survival',
          displayName: 'Survival',
          plan: plan,
          serverRoot: folder,
          dl: app.modpackEnv.downloader,
          now: sampleNow,
        ),
        throwsA(isA<LauncherProfileError>().having((e) => e.reason, 'reason', 'noLauncher')),
      );
    },
  );

  test('nuovo server da zero: niente sull\'hub prima del primo caricamento, poi #1', () async {
    final c = app.newServer
      ..name = 'Avventura'
      ..origin = NsOrigin.scratch
      ..mc = '1.21.1'
      ..loader = Loader.vanilla;
    c.debugSet(javas: sampleJavas);
    transport.routes['GET piston-meta.mojang.com/mc/game/version_manifest_v2.json'] = (_) =>
        jsonRes({
          'latest': {'release': '1.21.1'},
          'versions': [
            {
              'id': '1.21.1',
              'type': 'release',
              'url': 'https://piston-meta.mojang.com/v1/packages/x/1.21.1.json',
              'sha1': sha1Of(utf8.encode(jsonEncode(_mcJson))),
              'releaseTime': '2024-08-08T00:00:00+00:00',
            },
          ],
        });
    // primo tentativo: il JSON della versione non c'è
    final before = (await app.client!.spaces()).length;
    await c.acceptAndCreate();
    expect(c.failed, NsTask.server);
    expect((await app.client!.spaces()).length, before, reason: 'niente a metà sull\'hub');
    transport.routes['GET piston-meta.mojang.com/v1/packages/x/1.21.1.json'] = (_) =>
        HttpRes.bytes(200, utf8.encode(jsonEncode(_mcJson)));
    transport.routes['GET piston-data.mojang.com/server.jar'] = (_) =>
        HttpRes.bytes(200, _serverJar);
    await c.create();
    expect(c.failed, isNull, reason: '${c.error}');
    expect(c.done, isTrue);
    expect(c.firstGeneration, 1);
    final dest = app.defaultFolderFor(c.created!.id);
    expect(File(p.join(dest, 'server.jar')).existsSync(), isTrue);
    expect(File(p.join(dest, 'eula.txt')).readAsStringSync(), contains('eula=true'));
    expect(app.config.prefs['server.${c.created!.id}.xmx'], 6 * 1024);
  });
}

final _serverJar = utf8.encode('server-jar');
final _mcJson = {
  'downloads': {
    'server': {
      'url': 'https://piston-data.mojang.com/server.jar',
      'sha1': sha1Of(_serverJar),
      'size': _serverJar.length,
    },
  },
  'javaVersion': {'majorVersion': 21},
};
