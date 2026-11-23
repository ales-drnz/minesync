// Test della sessione con hub e server finti. I nomi citano le regole di
// docs/spec/behaviour.md.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ms_core/ms_core.dart';
import 'package:ms_core/testing/fake_hub.dart';
import 'package:ms_protocol/ms_protocol.dart';
import 'package:ms_session/ms_session.dart';
import 'package:ms_session/testing/fake_server.dart';
import 'package:test/test.dart';

void main() {
  late FakeHub hub;
  late HubClient client;
  late HashPool pool;
  late Directory tmp;
  late String space;
  late List<FakeServer> servers;

  setUpAll(() => pool = HashPool.spawn(2));
  tearDownAll(() => pool.close());
  setUp(() async {
    hub = await FakeHub.start()
      ..heartbeatMs = 50;
    client = HubClient(hub.uri, idleTimeout: const Duration(seconds: 5));
    tmp = Directory.systemTemp.createTempSync('ms_session');
    space = hub.createSpace('Survival');
    servers = [];
  });
  tearDown(() async {
    client.close(force: true);
    await hub.close();
    tmp.deleteSync(recursive: true);
  });

  String root() => '${tmp.path}/world';

  SyncEngine engine({int uploadLimit = 0}) => SyncEngine(
    client,
    space,
    root(),
    pool: pool,
    retryDelay: const Duration(milliseconds: 10),
    uploadLimit: uploadLimit,
  );

  Session session({
    SessionConfig config = const SessionConfig(
      autosaveEvery: Duration(milliseconds: 300),
      emptyStopAfter: null,
      maxRestarts: 0,
      flushWait: Duration(milliseconds: 500),
      quietStable: Duration(milliseconds: 100),
      quietCap: Duration(seconds: 2),
    ),
    int uploadLimit = 0,
    void Function(FakeServer)? setup,
    bool followHub = false,
  }) => Session(
    engine: engine(uploadLimit: uploadLimit),
    parse: minecraftParse,
    config: config,
    followHub: followHub,
    port: 25565,
    launch: () async {
      final s = FakeServer(root());
      setup?.call(s);
      servers.add(s);
      s.boot();
      return s;
    },
  );

  Future<T> until<T>(Stream<SessionEvent> events, bool Function(SessionEvent) test) async =>
      await events.firstWhere(test).timeout(const Duration(seconds: 10)) as T;

  String hubFile(String rel) => utf8.decode(hub.blobs[hub.head(space)!.manifest[rel]!.h]!);

  void putLocal(String rel, String content) => File('${root()}/$rel')
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  test('sessione completa: avvio, salvataggio automatico, stop e caricamento finale', () async {
    final s = session();
    final events = <SessionEvent>[];
    s.events.listen(events.add);
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single.play();
    final saved = await until<SavedToHub>(s.events, (e) => e is SavedToHub);
    expect(saved.generation, greaterThanOrEqualTo(1));
    expect(hubFile('world/level.dat'), 'world 1');
    await s.stop();
    await run;
    expect(s.state, SessionState.ended);
    expect(hubFile('world/level.dat'), 'world 1 saved at stop');
    // B-SESSION-04: ogni save-off ha il suo save-on
    final c = servers.single.commands;
    expect(c.where((x) => x == 'save-off').length, c.where((x) => x == 'save-on').length);
    expect(hub.head(space)!.summary.kind, GenerationKind.push);
    expect(events.whereType<SessionWarning>(), isEmpty);
  });

  test('B-SESSION-10 il lock dice "play", con porta e giocatori', () async {
    final s = session();
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single.join('alice');
    await until<PlayersChanged>(s.events, (e) => e is PlayersChanged);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final info = hub.lockInfos[space]!;
    expect(info['action'], 'play');
    expect(info['port'], 25565);
    expect(info['players'], ['alice']);
    await s.stop();
    await run;
  });

  test(
    'B-SESSION-04 uplink lento: save-on subito, niente nuovo save-off durante l\'upload',
    () async {
      final s = session(uploadLimit: 100 * 1024); // 100 KiB/s
      final run = s.run();
      await until<StateChanged>(
        s.events,
        (e) => e is StateChanged && e.state == SessionState.running,
      );
      final srv = servers.single..write('world/big.dat', 'x' * (300 * 1024));
      final sw = Stopwatch()..start();
      // il save-on arriva prima che l'upload (~3 s) sia finito
      while (!srv.commands.contains('save-on')) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
      await until<SavedToHub>(s.events, (e) => e is SavedToHub);
      // durante l'upload i tick sono stati saltati: un solo save-off fin qui
      expect(srv.commands.where((c) => c == 'save-off').length, 1);
      await s.stop();
      await run;
    },
  );

  test(
    'B-SESSION-05 salvataggio manuale durante l\'upload: in coda; stop annulla l\'upload',
    () async {
      final s = session(
        uploadLimit: 50 * 1024,
        config: const SessionConfig(
          autosaveEvery: Duration(hours: 1),
          emptyStopAfter: null,
          maxRestarts: 0,
          quietStable: Duration(milliseconds: 100),
        ),
      );
      final saved = <SavedToHub>[];
      s.events.listen((e) {
        if (e is SavedToHub) saved.add(e);
      });
      final run = s.run();
      await until<StateChanged>(
        s.events,
        (e) => e is StateChanged && e.state == SessionState.running,
      );
      servers.single.write('world/big.dat', 'y' * (2 << 20)); // 2 MiB a 50 KiB/s: ~40 s
      expect(s.saveNow(), SaveRequest.started);
      while (servers.single.commands.where((c) => c == 'save-on').isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(s.saveNow(), SaveRequest.queued);
      final sw = Stopwatch()..start();
      await s.stop();
      await run;
      expect(sw.elapsed, lessThan(const Duration(seconds: 15)));
      // l'autosave annullato non è segnalato; il caricamento finale sì
      expect(saved, hasLength(1));
      expect(hubFile('world/big.dat'), 'y' * (2 << 20));
    },
  );

  test('B-SESSION-06 crash durante il gioco: stato caricato, sessione in errore', () async {
    final s = session();
    final crashes = <ServerCrashed>[];
    s.events.listen((e) {
      if (e is ServerCrashed) crashes.add(e);
    });
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single
      ..play()
      ..crash();
    await run;
    expect(s.state, SessionState.failed);
    expect(crashes.single.restarting, isFalse);
    expect(hubFile('world/level.dat'), 'world 1');
  });

  test('G-16 dopo un crash il server riparte (al massimo N volte)', () async {
    final s = session(
      config: const SessionConfig(
        autosaveEvery: Duration(hours: 1),
        emptyStopAfter: null,
        maxRestarts: 2,
        quietStable: Duration(milliseconds: 100),
      ),
    );
    final run = s.run();
    for (var i = 0; i < 3; i++) {
      await until<StateChanged>(
        s.events,
        (e) => e is StateChanged && e.state == SessionState.running,
      );
      servers.last.crash();
    }
    await run;
    expect(servers, hasLength(3));
    expect(s.state, SessionState.failed);
  });

  test('B-SESSION-07 una scrittura 400 ms dopo la conferma entra nell\'istantanea', () async {
    final s = session(
      config: const SessionConfig(
        autosaveEvery: Duration(hours: 1),
        emptyStopAfter: null,
        maxRestarts: 0,
        quietStable: Duration(milliseconds: 700),
      ),
      setup: (srv) => srv.lateWrite = (
        const Duration(milliseconds: 400),
        'world/data/mod.dat',
        'scritto tardi',
      ),
    );
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    s.saveNow();
    await until<SavedToHub>(s.events, (e) => e is SavedToHub);
    expect(hubFile('world/data/mod.dat'), 'scritto tardi');
    await s.stop();
    await run;
  });

  test('G-18 salvataggio non confermato: niente istantanea, save-on comunque', () async {
    final s = session(setup: (srv) => srv.confirmSaves = false);
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single.play();
    final w = await until<SessionWarning>(s.events, (e) => e is SessionWarning);
    expect(w.code, 'saveNotConfirmed');
    expect(servers.single.commands, contains('save-on'));
    expect(hub.head(space), isNull);
    await s.stop();
    await run;
    expect(hubFile('world/level.dat'), 'world 1 saved at stop');
  });

  test('B-SESSION-08 spazio cancellato: stop pulito una volta sola', () async {
    final s = session();
    final alerts = <SessionAlert>[];
    s.events.listen((e) {
      if (e is SessionAlert) alerts.add(e);
    });
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    hub.deleteSpace(space);
    await run;
    expect(alerts.map((a) => a.kind), ['spaceGone']);
    expect(servers.single.stops, 1);
  });

  test('B-SESSION-03 lock rubato: allarme e stop, nessun caricamento finale', () async {
    final s = session(
      config: const SessionConfig(autosaveEvery: Duration(hours: 1), emptyStopAfter: null),
    );
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single.play();
    hub.stealLock(space, 'bob');
    await run;
    expect(s.state, SessionState.ended);
    expect(hub.head(space), isNull);
    // il mondo resta qui, intatto
    expect(File('${root()}/world/level.dat').readAsStringSync(), 'world 1 saved at stop');
  });

  test('G-17 server vuoto: spegnimento automatico e caricamento', () async {
    final s = session(
      config: const SessionConfig(
        autosaveEvery: Duration(hours: 1),
        emptyStopAfter: Duration(milliseconds: 400),
      ),
    );
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single.join('alice');
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(s.state, SessionState.running); // c'è qualcuno
    servers.single.leave('alice');
    await run.timeout(const Duration(seconds: 5));
    expect(hub.head(space)!.n, 1);
  });

  test('B-SESSION-20 "stop" dalla console = arresto pulito della sessione', () async {
    final s = session();
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    await s.send('stop');
    await run;
    expect(servers.single.stops, 1);
    expect(s.state, SessionState.ended);
  });

  test('/stop dato in gioco: arresto voluto, caricamento finale, niente crash', () async {
    final s = session();
    final crashes = <ServerCrashed>[];
    s.events.listen((e) {
      if (e is ServerCrashed) crashes.add(e);
    });
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    servers.single.play();
    await servers.single.stop(); // come se l'avesse chiesto il server stesso
    await run;
    expect(crashes, isEmpty);
    expect(s.state, SessionState.ended);
    expect(hubFile('world/level.dat'), 'world 1 saved at stop');
  });

  test('B-SESSION-01 modifiche locali non divergenti caricate prima del pull', () async {
    putLocal('a.txt', '1');
    final lock = await client.acquireLock(space, const LockInfo());
    await engine().push(lock: lock);
    await client.releaseLock(space, lock.token);
    putLocal('a.txt', 'non caricato');
    final s = session();
    final run = s.run();
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    expect(hub.head(space)!.n, 2);
    expect(hubFile('a.txt'), 'non caricato');
    await s.stop();
    await run;
  });

  test('B-SESSION-02 modifiche divergenti: la sessione non parte; con discard sì', () async {
    putLocal('a.txt', '1');
    final lock = await client.acquireLock(space, const LockInfo());
    await engine().push(lock: lock);
    await client.releaseLock(space, lock.token);
    hub.commitDirect(space, {'a.txt': utf8.encode('di bob')});
    putLocal('a.txt', 'mio');
    await expectLater(
      session().run(),
      throwsA(isA<SyncException>().having((e) => e.kind, 'kind', SyncErrorKind.dirtyLocal)),
    );
    expect(hub.head(space)!.n, 2);
    final s = session();
    final run = s.run(discardLocal: true);
    await until<StateChanged>(
      s.events,
      (e) => e is StateChanged && e.state == SessionState.running,
    );
    expect(File('${root()}/a.txt').readAsStringSync(), 'di bob');
    await s.stop();
    await run;
  });

  test('il parser vero riconosce le righe del server finto e ignora la chat', () {
    expect(minecraftParse('[12:00:00] [Server thread/INFO]: Saved the game'), isA<FactSaved>());
    expect(minecraftParse('[12:00:00] [Server thread/INFO]: <bob> Saved the game'), isNull);
    expect(
      minecraftParse('[12:00:00] [Server thread/INFO]: alice joined the game'),
      isA<FactJoined>(),
    );
    for (final l in [
      '[Server thread/INFO]: Done (1.0s)!',
      '[Server thread/INFO]: Saved the game',
    ]) {
      expect(minecraftParse('[12:00:00] $l'), isNotNull, reason: l);
    }
  });

  test('lock di un altro: la sessione non parte', () async {
    hub.stealLock(space, 'bob');
    await expectLater(session().run(), throwsA(isA<ApiError>()));
  });

  group('impostazioni delle sessioni dall\'hub', () {
    const hubSessions = SessionSettings(
      autosaveMinutes: 7,
      autostop: false,
      autostopMinutes: 3,
      crashRestarts: 4,
    );

    Future<void> runUntilPlaying(Session s) async {
      await until<StateChanged>(
        s.events,
        (e) => e is StateChanged && e.state == SessionState.running,
      );
    }

    test('con followHub valgono quelle effettive dello spazio', () async {
      hub.setSettings(space, const SpaceSettings(sessions: hubSessions));
      final s = session(followHub: true);
      final applied = s.events.firstWhere((e) => e is SettingsApplied);
      final run = s.run();
      await runUntilPlaying(s);
      expect(((await applied) as SettingsApplied).config.autosaveEvery.inMinutes, 7);
      expect(s.config.autosaveEvery, const Duration(minutes: 7));
      expect(s.config.emptyStopAfter, const Duration(minutes: 3));
      expect(s.config.maxRestarts, 4);
      // i tempi interni restano quelli della sessione
      expect(s.config.flushWait, const Duration(milliseconds: 500));
      expect(s.autostop, isFalse);
      expect(s.nextAutosave!.difference(DateTime.now()).inMinutes, greaterThanOrEqualTo(6));
      // la scelta locale vince sull'hub per questa sessione
      s.autostop = true;
      expect(s.autostop, isTrue);
      await s.stop();
      await run;
      expect(s.nextAutosave, isNull);
    });

    test('senza followHub (o con un hub che non le manda) restano quelle date', () async {
      hub.setSettings(space, const SpaceSettings(sessions: hubSessions));
      final s = session();
      final run = s.run();
      await runUntilPlaying(s);
      expect(s.config.autosaveEvery, const Duration(milliseconds: 300));
      expect(s.autostop, isTrue);
      await s.stop();
      await run;

      hub.setSettings(space, null);
      final t = session(followHub: true);
      final run2 = t.run();
      await runUntilPlaying(t);
      expect(t.config.autosaveEvery, const Duration(milliseconds: 300));
      await t.stop();
      await run2;
    });

    test('riletti dopo ogni salvataggio automatico', () async {
      // periodo breve all'inizio, poi l'admin cambia lo spegnimento
      final s = session(followHub: true);
      final run = s.run();
      await runUntilPlaying(s);
      servers.single.play();
      hub.setSettings(
        space,
        const SpaceSettings(sessions: SessionSettings(autosaveMinutes: 9, crashRestarts: 1)),
      );
      final applied = await until<SettingsApplied>(s.events, (e) => e is SettingsApplied);
      expect(applied.config.autosaveEvery, const Duration(minutes: 9));
      expect(s.config.maxRestarts, 1);
      await s.stop();
      await run;
    });
  });
}
