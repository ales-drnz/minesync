// Stato locale dei server contro l'hub vero in-process: collegamento,
// carica, scarica, verifica, modifiche locali protette, storia, ripristino,
// sblocco forzato e pre-scarico in background.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:minesync_desktop/src/l10n/l10n.dart';
import 'package:minesync_desktop/src/platform/platform.dart';
import 'package:minesync_desktop/src/state/app_state.dart';
import 'package:minesync_desktop/src/state/space_state.dart';
import 'package:minesync_hub/minesync_hub.dart';
import 'package:ms_core/ms_core.dart';
import 'package:ms_protocol/ms_protocol.dart';

import 'app_state_test.dart' show until;

void main() {
  late Directory tmp;
  late Hub hub;
  late AppState app;
  late String hubAddr;
  late String spaceId;

  AppState newApp(String name) => AppState(
    AppDeps(
      configDir: '${tmp.path}/$name',
      platform: PlatformServices.inert(),
      pollEvery: const Duration(seconds: 30),
      env: {'HOME': '${tmp.path}/home-$name'},
    ),
  );

  void write(String folder, String rel, String text) {
    final f = File('$folder/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('ms_space');
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
    hubAddr = '127.0.0.1:${hub.port}';
    app = newApp('a');
    await app.setPref('prefetch', false);
    await app.connectTo(hubAddr);
    spaceId = (await app.createSpace('Survival', Profile.minecraft)).id;
  });

  tearDown(() async {
    app.dispose();
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  test('cartella proposta sotto ~/MineSync e mostrata con ~', () {
    final ss = app.spaceState(spaceId);
    expect(ss.linked, isFalse);
    expect(ss.suggestedFolder, '${tmp.path}/home-a/MineSync/$spaceId');
    expect(app.displayPath(ss.suggestedFolder), '~/MineSync/$spaceId');
  });

  test('carica, poi un altro carica: la copia locale vede cosa manca e lo scarica', () async {
    final ss = app.spaceState(spaceId);
    final folder = '${tmp.path}/world-a';
    await ss.linkTo(folder);
    expect(ss.scan.exists, isTrue);
    expect(ss.baseN, isNull);
    write(folder, 'world/level.dat', 'uno');
    write(folder, 'mods/a.jar', 'jar');
    final pushed = await ss.push(message: 'prima');
    expect(pushed?.generation?.n, 1);
    expect(ss.outcome, isA<PushDone>());
    expect(ss.baseN, 1);
    expect(ss.scan.mods, 1);
    // l'evento dal vivo della presa del lock può arrivare dopo il rilascio
    // (CI lenta): si rilegge lo stato dall'hub prima di controllare
    await app.refreshSpaces();
    expect(app.space(spaceId)!.lock, isNull, reason: 'il lock del caricamento è rilasciato');

    // un secondo PC dello stesso gruppo carica la #2
    final other = newApp('b');
    addTearDown(other.dispose);
    await other.setPref('prefetch', false);
    await other.connectTo(hubAddr);
    final os = other.spaceState(spaceId);
    final folderB = '${tmp.path}/world-b';
    await os.linkTo(folderB);
    expect((await os.pull())?.n, 1);
    write(folderB, 'world/level.dat', 'due!');
    write(folderB, 'world/new.dat', 'nuovo');
    expect((await os.push())?.generation?.n, 2);

    await app.refreshSpaces();
    await ss.refresh();
    expect(ss.pending, isNotNull);
    expect(ss.pending!.from, 1);
    expect(ss.pending!.to, 2);
    expect(ss.pending!.files, 2);
    expect(ss.upToDate, isFalse);

    final r = await ss.pull();
    expect(r?.n, 2);
    expect(ss.baseN, 2);
    expect(ss.pending, isNull);
    expect(File('$folder/world/level.dat').readAsStringSync(), 'due!');
  });

  test('scaricare non sovrascrive modifiche mai caricate', () async {
    final ss = app.spaceState(spaceId);
    final folder = '${tmp.path}/world-a';
    await ss.linkTo(folder);
    write(folder, 'world/level.dat', 'uno');
    await ss.push();

    final other = newApp('b');
    addTearDown(other.dispose);
    await other.setPref('prefetch', false);
    await other.connectTo(hubAddr);
    final os = other.spaceState(spaceId);
    await os.linkTo('${tmp.path}/world-b');
    await os.pull();
    write('${tmp.path}/world-b', 'world/level.dat', 'altro');
    await os.push();

    write(folder, 'world/level.dat', 'mio');
    await app.refreshSpaces();
    expect(await ss.pull(), isNull);
    final o = ss.outcome! as OpFailed;
    expect(o.op, SpaceOp.pull);
    expect((o.error as SyncException).kind, SyncErrorKind.dirtyLocal);
    expect((o.error as SyncException).diverged, isTrue);
    expect(File('$folder/world/level.dat').readAsStringSync(), 'mio');

    // scegliendo di scartarle, finiscono in un backup
    final r = await ss.pull(discardLocal: true);
    expect(r?.backup, isNotNull);
    expect(File('$folder/world/level.dat').readAsStringSync(), 'altro');
  });

  test('verifica: tutto a posto, poi un file cambiato', () async {
    final ss = app.spaceState(spaceId);
    final folder = '${tmp.path}/world-a';
    await ss.linkTo(folder);
    write(folder, 'world/level.dat', 'uno');
    await ss.push();
    final ok = await ss.verify();
    expect(ok!.diff.isEmpty, isTrue);
    expect(ok.files, 1);
    write(folder, 'world/level.dat', 'rovinato');
    final bad = await ss.verify();
    expect(bad!.diff.changed, ['world/level.dat']);
  });

  test('avanzamento con fase e byte durante il caricamento', () async {
    final ss = app.spaceState(spaceId);
    final folder = '${tmp.path}/world-a';
    await ss.linkTo(folder);
    write(folder, 'world/big.dat', 'x' * 300000);
    final phases = <String>{};
    void listen() {
      final t = ss.transfer;
      if (t != null) phases.add(t.phase);
    }

    ss.addListener(listen);
    await ss.push();
    ss.removeListener(listen);
    expect(phases, containsAll(['start', 'scan', 'upload', 'commit']));
    expect(ss.transfer, isNull);
    expect(ss.busy, isFalse);
  });

  test('storia, differenze e ripristino', () async {
    final ss = app.spaceState(spaceId);
    final folder = '${tmp.path}/world-a';
    await ss.linkTo(folder);
    write(folder, 'world/level.dat', 'uno');
    write(folder, 'world/old.dat', 'vecchio');
    await ss.push();
    write(folder, 'world/level.dat', 'due');
    File('$folder/world/old.dat').deleteSync();
    write(folder, 'world/new.dat', 'nuovo');
    await ss.push();

    await ss.loadHistory();
    expect([for (final g in ss.history) g.n], [2, 1]);
    expect(ss.historyEnd, isTrue);
    final d = await ss.diff(2);
    expect(d.parent, 1);
    expect([for (final f in d.added) f.$1], ['world/new.dat']);
    expect([for (final f in d.changed) f.$1], ['world/level.dat']);
    expect(d.removed.single, ('world/old.dat', 7));

    final g = await app.restore(spaceId, 1);
    expect(g.n, 3);
    expect(g.kind, GenerationKind.restore);
    expect(g.restoredFrom, 1);
    expect(ss.history, isEmpty, reason: 'la storia si rilegge dopo un ripristino');
    await ss.loadHistory();
    expect(ss.history.first.n, 3);
  });

  test('sblocco forzato di un lock tenuto da un altro', () async {
    final other = HubClient(Uri.parse('http://$hubAddr/'));
    addTearDown(other.close);
    await other.acquireLock(spaceId, const LockInfo(action: 'play'));
    await app.refreshSpaces();
    expect(app.space(spaceId)!.lock, isNotNull);
    await app.forceUnlock(spaceId);
    expect(app.space(spaceId)!.lock, isNull);
  });

  test('pre-scarico: le novità di un server collegato arrivano da sole', () async {
    final ss = app.spaceState(spaceId);
    await ss.linkTo('${tmp.path}/world-a');
    await app.setPref('prefetch', null);

    final other = newApp('b');
    addTearDown(other.dispose);
    await other.setPref('prefetch', false);
    await other.connectTo(hubAddr);
    final os = other.spaceState(spaceId);
    await os.linkTo('${tmp.path}/world-b');
    write('${tmp.path}/world-b', 'world/level.dat', 'uno');
    await os.push();

    await until(() => ss.baseN == 1);
    expect(File('${tmp.path}/world-a/world/level.dat').readAsStringSync(), 'uno');
    expect((ss.outcome! as PullDone).background, isTrue);
    expect(app.prefetching, isNull);
  });

  test('avvisami quando si libera: notifica sul desktop una volta sola', () async {
    final notes = app.deps.platform.notifications as InertNotifications;
    final other = HubClient(Uri.parse('http://$hubAddr/'));
    addTearDown(other.close);
    final g = await other.acquireLock(spaceId, const LockInfo(action: 'play'));
    await app.setNotifyWhenFree(spaceId, true);
    await other.releaseLock(spaceId, g.token);
    await until(() => notes.shown.isNotEmpty);
    expect(notes.shown.single, ('Survival', AppStrings(app.lang).session.notifyFree));
    expect(app.notifyWhenFree(spaceId), isFalse);
  });
}
